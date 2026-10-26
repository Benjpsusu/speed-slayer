#!/usr/bin/env bash
# Optional, shared TCP Brutal manager for Speed Slayer and Speed Slayer Lite.
set -Eeuo pipefail
umask 077

BRUTAL_VERSION=2.0.0
BRUTAL_ARCHIVE_SHA=6a6e00a2bc3ea95220a4fbacde1069b61abaf24386b4db75e0ce3c7363ed5579
BRUTAL_DIR=/etc/speed-slayer-brutal
BRUTAL_RULES=$BRUTAL_DIR/rules.tsv
BRUTAL_PROC=/proc/net/tcp_brutal/rules
BRUTAL_MODULE_VERSION=/sys/module/brutal/version
BRUTAL_MANAGER=/usr/local/lib/speed-slayer/tcp-brutal.sh
BRUTAL_BIN=/usr/local/sbin/speed-brutal
BRUTAL_UNIT=/etc/systemd/system/speed-slayer-brutal.service
BRUTAL_AUTOLOAD=/etc/modules-load.d/99-speed-slayer-brutal.conf
BRUTAL_SERVICE=speed-slayer-brutal.service

b_log() { printf '[TCP Brutal] %s\n' "$*"; }
b_error() { printf '[TCP Brutal] %s\n' "$*" >&2; return 1; }
b_need() { command -v "$1" >/dev/null 2>&1 || b_error "缺少 $1；请先执行 install。"; }
b_root() { [[ $(id -u) == 0 ]] || b_error '请使用 root 执行。'; }

b_host() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    text = sys.argv[1]
    if '%' in text:
        raise ValueError('不支持带 zone 的 IPv6')
    net = ipaddress.ip_network(text, strict=True)
    ip = net.network_address
    if net.prefixlen != net.max_prefixlen:
        raise ValueError('只支持单个客户端 IP（IPv4 /32 或 IPv6 /128）')
    if ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_link_local:
        raise ValueError('不能使用回环、组播、未指定或链路本地地址')
    if getattr(ip, 'ipv4_mapped', None) or str(ip) == '255.255.255.255':
        raise ValueError('请使用普通单播 IPv4/IPv6 地址')
    print(net)
except ValueError as exc:
    sys.exit(f'目标 IP 无效：{exc}')
PY
}

b_rate() {
  [[ $1 =~ ^[1-9][0-9]{0,5}$ ]] && (( 10#$1 <= 100000 )) ||
    b_error '带宽必须是 1–100000 的整数，单位 Mbps。'
}

b_validate_rules() {
  [[ -f $BRUTAL_RULES ]] || return 0
  local host rate extra canonical
  local -A seen=()
  while IFS=$'\t' read -r host rate extra || [[ -n $host ]]; do
    [[ -n $host && -n $rate && -z $extra ]] || { b_error '规则文件格式错误。'; return 1; }
    canonical=$(b_host "$host") || return 1
    [[ $canonical == "$host" && -z ${seen[$host]:-} ]] || { b_error '规则文件有非规范或重复 IP。'; return 1; }
    b_rate "$rate" || return 1
    seen[$host]=1
  done < "$BRUTAL_RULES"
}

b_saved_rate() { awk -F '\t' -v host="$1" '$1 == host {print $2}' "$BRUTAL_RULES"; }
b_live_rate() {
  [[ -r $BRUTAL_PROC ]] || return 0
  awk -v host="$1" '{dst=""; rate=""; for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="dst")dst=a[2]; if(a[1]=="rate")rate=a[2]} if(dst==host)print rate}' "$BRUTAL_PROC"
}
b_family() { if [[ $1 == *:* ]]; then printf '%s\n' -6; else printf '%s\n' -4; fi; }

# Use numeric protocol/table IDs and structured output; never evaluate route text.
b_route_state() {
  local routes
  routes=$(ip "$(b_family "$1")" -j -N route show table all exact "$1") || return 1
  python3 - "$routes" <<'PY'
import json, sys
routes = json.loads(sys.argv[1])
if not routes:
    print('none')
elif len(routes) == 1 and str(routes[0].get('protocol')) == '233' and str(routes[0].get('table', 254)) in ('254', 'main'):
    print('owned')
else:
    print('foreign')
PY
}

b_preflight() {
  local host=$1 owned=$2 routes policies state live
  state=$(b_route_state "$host") || return 1
  [[ $state == none || ( $state == owned && $owned == 1 ) ]] || {
    b_error "目标 $host 已有其他路由，拒绝覆盖；请自行管理复杂路由。"; return 1;
  }
  live=$(b_live_rate "$host") || return 1
  [[ -z $live || $owned == 1 ]] || { b_error "目标 $host 已有外部 Brutal 规则，拒绝接管。"; return 1; }
  policies=$(ip "$(b_family "$host")" -j -N rule show) || return 1
  routes=$(ip "$(b_family "$host")" -j -N route get "${host%/*}") || return 1
  python3 - "$policies" "$routes" <<'PY'
import json, sys
rules, routes = map(json.loads, sys.argv[1:])
defaults = {0: 255, 32766: 254, 32767: 253}
for rule in rules:
    table = {'local': '255', 'main': '254', 'default': '253'}.get(str(rule.get('table')), str(rule.get('table')))
    if (str(defaults.get(rule.get('priority'))) != table or
        rule.get('src', 'all') != 'all' or rule.get('dst', 'all') != 'all' or
        set(rule) - {'priority', 'src', 'dst', 'table', 'protocol'}):
        sys.exit('检测到策略路由；请手动使用上游工具，本管理器不自动改写。')
if len(routes) != 1:
    sys.exit('无法确定唯一出站路由。')
route = routes[0]
if (route.get('type', 'unicast') != 'unicast' or not route.get('dev') or
    str(route.get('table', 254)) not in ('254', 'main') or
    any(key in route for key in ('encap', 'nhid', 'multipath', 'nexthops'))):
    sys.exit('本地地址或复杂出站路由不支持自动配置。')
PY
}

b_module_ready() {
  [[ -r $BRUTAL_MODULE_VERSION ]] || modprobe brutal || return 1
  [[ -r $BRUTAL_MODULE_VERSION && $(cat "$BRUTAL_MODULE_VERSION") == "$BRUTAL_VERSION" && -w $BRUTAL_PROC ]] ||
    b_error "需要已加载的 TCP Brutal $BRUTAL_VERSION 及可写的规则接口；请检查内核/容器权限。"
}

b_verify() {
  local host=$1 rate=$2 state live
  state=$(b_route_state "$host") || return 1
  live=$(b_live_rate "$host") || return 1
  [[ $state == owned && $live == "$((rate * 125000))" ]] || {
    b_error "目标 $host 的规则或路由验证失败。"; return 1;
  }
  local route
  route=$(ip "$(b_family "$host")" -j -N route show table main exact "$host") || return 1
  python3 - "$route" <<'PY'
import json, sys
routes = json.loads(sys.argv[1])
if len(routes) != 1 or not any(metric.get('congestion') == 'brutal' for metric in routes[0].get('metrics', [])):
    sys.exit('目标路由未选择 brutal。')
PY
}

b_apply() { brutalctl add "$1" "$2" && b_verify "$1" "$2"; }

# Only remove destinations recorded in our state; never use brutalctl flush.
b_remove_live() {
  local host=$1 state
  if [[ -n $(b_live_rate "$host") ]]; then
    brutalctl del "$host" || return 1
  fi
  state=$(b_route_state "$host") || return 1
  if [[ $state == owned ]]; then
    ip "$(b_family "$host")" route del "$host" proto 233 || return 1
  elif [[ $state == foreign ]]; then
    b_error "目标 $host 存在其他路由，已保留；请检查。"; return 1
  fi
  [[ $(b_route_state "$host") == none && -z $(b_live_rate "$host") ]] ||
    b_error "目标 $host 清理不完整，保留记录以便重试。"
}

b_write_rule() {
  local host=$1 rate=${2:-} tmp
  tmp=$(mktemp "$BRUTAL_DIR/rules.XXXXXX") || return 1
  awk -F '\t' -v host="$host" '$1 != host' "$BRUTAL_RULES" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [[ -n $rate ]]; then printf '%s\t%s\n' "$host" "$rate" >> "$tmp" || { rm -f "$tmp"; return 1; }; fi
  cp "$BRUTAL_RULES" "$BRUTAL_RULES.bak" && chmod 600 "$tmp" && mv -f "$tmp" "$BRUTAL_RULES"
}

b_add() {
  local host rate old owned=0
  host=$(b_host "$1") || return 1
  rate=$2
  b_rate "$rate" && b_validate_rules && b_module_ready || return 1
  [[ -f $BRUTAL_UNIT && -f $BRUTAL_MANAGER && -f $BRUTAL_RULES ]] || { b_error '请先执行 install。'; return 1; }
  old=$(b_saved_rate "$host") || return 1
  [[ -z $old ]] || owned=1
  b_preflight "$host" "$owned" || return 1
  # Persist ownership before touching the kernel, so interruption is recoverable.
  b_write_rule "$host" "$rate" || return 1
  if systemctl enable "$BRUTAL_SERVICE" && b_apply "$host" "$rate"; then
    b_log "$host 合计 ${rate} Mbps，已保存；请新建客户端连接。"
    return 0
  fi
  b_error '添加失败，正在恢复上一条配置。' || true
  if [[ -n $old ]]; then
    if b_apply "$host" "$old"; then b_write_rule "$host" "$old" || return 1; fi
  elif b_remove_live "$host"; then
    b_write_rule "$host" || return 1
  fi
  if [[ ! -s $BRUTAL_RULES ]]; then systemctl disable "$BRUTAL_SERVICE" || return 1; fi
  b_error "操作失败；请执行 status 检查。未清理的目标保留在 $BRUTAL_RULES 中，可用 del/disable 重试。"
}

b_del() {
  local host
  host=$(b_host "$1") || return 1
  b_validate_rules || return 1
  [[ -f $BRUTAL_RULES && -n $(b_saved_rate "$host") ]] || { b_error '该 IP 不属于本管理器，未做修改。'; return 1; }
  b_remove_live "$host" && b_write_rule "$host" || return 1
  if [[ ! -s $BRUTAL_RULES ]]; then systemctl disable "$BRUTAL_SERVICE" || return 1; fi
  b_log "已删除 $host；已有连接需要关闭后重连才会退出 Brutal。"
}

b_disable() {
  b_validate_rules || return 1
  local host rate failed=0
  # Disable boot restoration first, even if kernel cleanup later fails.
  if [[ -f $BRUTAL_UNIT ]]; then systemctl disable "$BRUTAL_SERVICE" || return 1; fi
  if [[ -s $BRUTAL_RULES ]]; then
    cp "$BRUTAL_RULES" "$BRUTAL_DIR/disabled-rules.tsv" || return 1
    while IFS=$'\t' read -r host rate; do
      if b_remove_live "$host"; then b_write_rule "$host" || return 1; else failed=1; fi
    done < "$BRUTAL_DIR/disabled-rules.tsv"
  fi
  (( failed == 0 )) || { b_error '部分规则未清理，已保留失败条目；修复后重试 disable。'; return 1; }
  b_log '已停用并清除本管理器的持久规则；备份保存在 disabled-rules.tsv。已有连接需重连。'
}

b_restore() {
  [[ -s $BRUTAL_RULES ]] || return 0
  b_validate_rules && b_module_ready || return 1
  local host rate failed=0
  while IFS=$'\t' read -r host rate; do
    if ! b_preflight "$host" 1; then failed=1; continue; fi
    if ! b_apply "$host" "$rate"; then
      b_remove_live "$host" || true
      failed=1
    fi
  done < "$BRUTAL_RULES"
  (( failed == 0 )) || b_error '部分开机规则恢复失败；查看 journalctl -u speed-slayer-brutal。'
}

b_status() {
  printf '目标版本: %s\n' "$BRUTAL_VERSION"
  printf '已加载版本: %s\n' "$(cat "$BRUTAL_MODULE_VERSION" 2>/dev/null || printf '未加载')"
  printf '系统默认拥塞控制: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  printf '开机恢复: %s\n' "$(systemctl is-enabled "$BRUTAL_SERVICE" 2>/dev/null || true)"
  printf '\n保存的规则（IP / Mbps）：\n'
  if [[ -s $BRUTAL_RULES ]]; then cat "$BRUTAL_RULES"; else printf '无；未通过本管理器启用加速。\n'; fi
  printf '\n内核中的全部 Brutal 规则（可能包含其他工具配置）：\n'
  if [[ -r $BRUTAL_PROC ]]; then brutalctl list || return 1; else printf '模块未加载或没有 v2 规则接口。\n'; fi
  if [[ -s $BRUTAL_RULES ]]; then
    b_validate_rules || return 1
    local host rate failed=0
    while IFS=$'\t' read -r host rate; do b_verify "$host" "$rate" || failed=1; done < "$BRUTAL_RULES"
    (( failed == 0 )) || return 1
  fi
}

b_check_kernel() {
  local release
  release=$(uname -r)
  [[ $release =~ ^([0-9]+)\.([0-9]+) ]] || { b_error '无法识别内核版本。'; return 1; }
  (( BASH_REMATCH[1] > 5 || (BASH_REMATCH[1] == 5 && BASH_REMATCH[2] >= 10) )) ||
    b_error 'TCP Brutal v2 要求 Linux >= 5.10；请先升级并启动受支持内核。'
}

b_download() {
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 -o "$2" "$1" || return 1
  printf '%s  %s\n' "$3" "$2" | sha256sum -c - || return 1
}

b_install() (
  [[ $(uname -s) == Linux ]] && b_check_kernel || return 1
  [[ -d /run/systemd/system ]] || { b_error '要求运行 systemd 的 Debian/Ubuntu。'; return 1; }
  if [[ -e /.dockerenv || -e /run/.containerenv ]] || systemd-detect-virt --container --quiet; then
    b_error '容器内不安装宿主机内核模块；请让宿主机管理员部署。'; return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || { b_error '仅支持 Debian/Ubuntu。'; return 1; }
  if [[ -r $BRUTAL_MODULE_VERSION && $(cat "$BRUTAL_MODULE_VERSION") != "$BRUTAL_VERSION" ]]; then
    b_error '已加载其他版本 Brutal；请先自行处理版本切换，本脚本不卸载活跃模块。'; return 1
  fi
  local entry
  for entry in /var/lib/dkms/tcp-brutal/*; do
    [[ -d $entry && ! -L $entry ]] || continue
    [[ ${entry##*/} == "$BRUTAL_VERSION" ]] || { b_error '存在其他 DKMS 版本，请先自行处理升级。'; return 1; }
  done
  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl python3 iproute2 util-linux kmod build-essential dkms || return 1
  if [[ ! -d /lib/modules/$(uname -r)/build ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$(uname -r)" || return 1
  fi
  [[ -d /lib/modules/$(uname -r)/build ]] || { b_error '缺少当前运行内核的 headers。'; return 1; }
  local tmp source_dir
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  source_dir="/usr/src/tcp-brutal-$BRUTAL_VERSION"
  if [[ ! -d /var/lib/dkms/tcp-brutal/$BRUTAL_VERSION ]]; then
    b_download "https://github.com/HyNetworks/tcp-brutal/releases/download/v$BRUTAL_VERSION/tcp-brutal.dkms.tar.gz" \
      "$tmp/brutal.tar.gz" "$BRUTAL_ARCHIVE_SHA" || return 1
    # Recent DKMS versions removed ldtarball; use the upstream source-tree format.
    tar -xzf "$tmp/brutal.tar.gz" -C "$tmp" || return 1
    if [[ -d $source_dir ]]; then
      diff -qr "$tmp/dkms_source_tree" "$source_dir" || { b_error '已有未注册源码与固定版本不一致。'; return 1; }
    else
      cp -a "$tmp/dkms_source_tree" "$source_dir" || return 1
    fi
    dkms add -m tcp-brutal -v "$BRUTAL_VERSION" || return 1
  fi
  dkms install -m tcp-brutal -v "$BRUTAL_VERSION" -k "$(uname -r)" || return 1
  cc -O2 -Wall -o "$tmp/brutalctl" "$source_dir/tools/brutalctl.c" || return 1
  install -m 0755 "$tmp/brutalctl" /usr/local/bin/brutalctl || return 1
  b_module_ready || return 1
  install -d -m 0700 "$BRUTAL_DIR" || return 1
  [[ -f $BRUTAL_RULES ]] || : > "$BRUTAL_RULES"
  b_validate_rules || return 1
  chmod 600 "$BRUTAL_RULES" || return 1
  install -d -m 0755 "$(dirname "$BRUTAL_MANAGER")" || return 1
  # Stage the executable first, including when reinstalling via speed-brutal.
  install -m 0755 "${BASH_SOURCE[0]}" "$BRUTAL_MANAGER.new" && mv -f "$BRUTAL_MANAGER.new" "$BRUTAL_MANAGER" || return 1
  ln -sfn "$BRUTAL_MANAGER" "$BRUTAL_BIN" || return 1
  printf 'brutal\n' > "$BRUTAL_AUTOLOAD" || return 1
  cat > "$BRUTAL_UNIT" <<EOF
[Unit]
Description=Restore Speed Slayer TCP Brutal destination rules
Wants=network-online.target
After=network-online.target systemd-modules-load.service
Before=xray-lite.service xray.service

[Service]
Type=oneshot
ExecStart=/bin/bash $BRUTAL_MANAGER restore
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$BRUTAL_UNIT" "$BRUTAL_AUTOLOAD" || return 1
  systemctl daemon-reload || return 1
  b_log '安装完成。未添加规则时不改变任何连接的算法；全局 BBR/FQ 保持原值。'
  b_log '使用 speed-brutal add 客户端公网IP Mbps 添加规则。'
)

b_uninstall() {
  b_disable || return 1
  rm -f -- "$BRUTAL_UNIT" "$BRUTAL_AUTOLOAD" "$BRUTAL_BIN" "$BRUTAL_MANAGER" || return 1
  systemctl daemon-reload || return 1
  b_log "管理器已卸载。保留 $BRUTAL_DIR 备份，以及共享的 DKMS 模块和 brutalctl，避免影响其他应用。"
}

b_help() {
  cat <<'EOF'
TCP Brutal v2（可选；不修改全局 BBR，不自动用于 Argo/QUIC）
用法：speed-brutal <命令>
  install          安装固定版本模块及管理器；无规则时不加速
  add <IP> <Mbps>  添加/更新单个客户端的总发送速率，并启用开机恢复
  del <IP>         删除本管理器的一条规则
  status | list    查看持久规则、内核规则与路由是否一致
  disable          清除本管理器的所有规则并关闭开机恢复，保留备份
  restore          重放保存的规则（systemd 开机调用）
  uninstall        停用并移除管理器，保留共享内核模块和备份
  menu             交互菜单

IP 支持 IPv4 /32、IPv6 /128；不接受网段、默认路由和策略路由。
发送到该 IP 的所有 TCP 连接共享带宽，包括其他程序；UDP 不受影响。
Mbps 应按 VPS 到客户端的实际可用带宽设置，不使用 VPS Speedtest 值。
添加规则后请新建连接；删除规则后已有连接仍需关闭重连。
EOF
}

b_menu() {
  local choice host rate
  while true; do
    printf '\nTCP Brutal（直连 TCP 可选加速）\n1. 安装模块\n2. 添加/修改客户端规则\n3. 查看状态\n4. 删除规则\n5. 停用全部自有规则\n6. 卸载管理器\n0. 返回\n'
    read -r -p '请选择: ' choice || return 0
    case $choice in
      1) bash "${BASH_SOURCE[0]}" install || true ;;
      2) read -r -p '客户端公网 IP: ' host || return 0
         read -r -p '实际可用总带宽 Mbps: ' rate || return 0
         bash "${BASH_SOURCE[0]}" add "$host" "$rate" || true ;;
      3) bash "${BASH_SOURCE[0]}" status || true ;;
      4) read -r -p '要删除的客户端 IP: ' host || return 0
         bash "${BASH_SOURCE[0]}" del "$host" || true ;;
      5) bash "${BASH_SOURCE[0]}" disable || true ;;
      6) bash "${BASH_SOURCE[0]}" uninstall && return 0 ;;
      0) return 0 ;;
      *) b_log '无效选择。' ;;
    esac
  done
}

b_main() {
  local action=${1:-menu}
  case $action in
    help|-h|--help) b_help; return 0 ;;
    menu) b_root && b_menu; return $? ;;
    add) [[ $# == 3 ]] || { b_help; return 2; } ;;
    del) [[ $# == 2 ]] || { b_help; return 2; } ;;
    install|status|list|disable|restore|uninstall) [[ $# == 1 ]] || { b_help; return 2; } ;;
    *) b_help; return 2 ;;
  esac
  b_root || return 1
  [[ $(uname -s) == Linux ]] || { b_error '此命令只支持 Linux。'; return 1; }
  b_need flock || return 1
  exec 9>/run/speed-slayer-brutal.lock
  flock -w 30 9 || { b_error '另一项 Brutal 操作仍在运行，请稍后重试。'; return 1; }
  if [[ $action != install ]]; then b_need python3 && b_need ip || return 1; fi
  case $action in
    install) b_install ;;
    add) b_need brutalctl && b_add "$2" "$3" ;;
    del) b_del "$2" ;;
    status|list) b_status ;;
    disable) b_disable ;;
    restore) b_need brutalctl && b_restore ;;
    uninstall) b_uninstall ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then b_main "$@"; fi
