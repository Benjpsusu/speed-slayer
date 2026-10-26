# Speed Slayer Lite

只部署三种 Xray 入站，不安装 Nginx，不提供 HTTP 订阅：

- VMess + WebSocket + Cloudflare Tunnel
- Shadowsocks 2022 (`2022-blake3-aes-128-gcm`)
- VLESS + XHTTP + REALITY（独立随机路径，`mode=auto`，不启用 Vision flow）

## 端口

| 默认端口 | 监听地址 | 用途 | 防火墙 |
| --- | --- | --- | --- |
| `30000/tcp` | `127.0.0.1` | VMess WebSocket 源站 | 不开放 |
| `30001/tcp+udp` | `0.0.0.0` / `[::]` | Shadowsocks 2022 | 开放 |
| `30002/tcp` | `0.0.0.0` / `[::]` | VLESS XHTTP + REALITY | 开放 |
| `30003/tcp` | `127.0.0.1` | REALITY 防盗用守门入站 | 不开放 |

`cloudflared` 还需要出站访问 Cloudflare，通常为 `7844/tcp+udp`，失败时可回退到 `443/tcp`。

XHTTP + REALITY 直连只需要对应的 **TCP** 端口，不需要开放同号 UDP。默认保持 `30002`，新安装可用 `REALITY_PORT=443` 改为 `443/TCP`；此时脚本为低权限 Xray 服务授予 `CAP_NET_BIND_SERVICE`，并检查端口是否已被占用。

## 安装

支持 Debian 11+、Ubuntu 20.04+，架构为 amd64 或 arm64。必须用 root 执行。
系统必须使用 systemd；不支持未运行 systemd 的容器环境。

Quick Tunnel（自动生成临时 `trycloudflare.com` 域名）：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh)
```

上面的命令要求当前 Shell 已经是 root。普通用户请使用：

```bash
sudo -i bash -c 'bash <(curl -fsSL --proto "=https" --tlsv1.2 https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh)'
```

安装成功后会自动输出 VMess、SS2022 和 VLESS 连接信息，不需要再手动执行 `show`。如果 Quick Tunnel 启动超过等待时间，再执行 `sudo speed-slayer-lite show`。

### 旧版 TCP / Vision 节点一键切换为 XHTTP

仅替换脚本或运行 `show` 不会改变现有入站。以下命令以 **root** 执行；需先将新版文件上传到 GitHub：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh) migrate-xhttp
```

已下载新版脚本时，也可执行 `sudo bash install.sh migrate-xhttp`；本机快捷命令已更新后可用 `sudo speed-slayer-lite migrate-xhttp`。

迁移保留原来的端口、UUID、REALITY 密钥、short ID、SNI，以及 VMess/SS2022 和已有守门配置，只切换 VLESS 传输并生成匹配的新链接。会按需安装 Python 3，备份到 `/etc/speed-slayer-lite/backup-xhttp-<时间>.<随机后缀>/`，先通过 `xray run -test`，再切换配置并重启 Xray。切换或服务启动失败时自动恢复配置、状态、安装脚本和原节点信息文件；自动恢复失败会报告备份位置。

**迁移会短暂断开连接，完成后必须重新导入 VLESS 链接。** Xray 重启可能连带重启 cloudflared，Quick Tunnel 域名可能变化，此时 VMess 也需重新导入。重复迁移保留已生成的 XHTTP 路径。迁移不会修改端口；环境变量 `REALITY_PORT`、`XHTTP_PATH` 的定制只用于新安装。

已有自定义 XHTTP 模式/额外参数、state 与配置中的 UUID/端口不一致，或自定义的入站类型，不自动覆盖。没有 `reality-guard` 的更早旧安装不会在迁移时自动新增守门入站。

### 自定义新安装

命名 Tunnel（推荐，先在 Cloudflare 控制台创建 Tunnel，并将 Public Hostname 的 Service 指向 `http://localhost:30000`）：

```bash
sudo ARGO_MODE=token \
  ARGO_TOKEN='你的 Tunnel token' \
  ARGO_DOMAIN='你的域名.example.com' \
  bash install.sh install
```

自定义端口及 REALITY 伪装站点：

```bash
sudo VMESS_PORT=31000 SS_PORT=31001 REALITY_PORT=31002 \
  REALITY_GUARD_PORT=31003 \
  REALITY_SERVER_NAME=learn.microsoft.com \
  bash install.sh install
```

希望新安装使用 **443/TCP**，以 root 执行：

```bash
REALITY_PORT=443 bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh)
```

也可用 `sudo REALITY_PORT=443 bash install.sh install`。请在系统防火墙与云安全组放行 `443/TCP`；若已有网站占用 443，脚本会停止，应选择其他空闲端口。其他端口参数继续只接受 `1024–65535`。

XHTTP 路径默认随机生成并保存到 `state`；新安装可设置 `XHTTP_PATH=/your_random_path`，允许以 `/` 开头、后接 1–128 个字母、数字、`/`、`_` 或 `-`。

安装完成后，连接信息只写到 `/etc/speed-slayer-lite/client-info.txt`，权限 `0600`：

```bash
sudo speed-slayer-lite show
sudo speed-slayer-lite status
sudo speed-slayer-lite repair-argo
sudo speed-slayer-lite migrate-xhttp
sudo speed-slayer-lite uninstall
```

Quick Tunnel 域名可能在首次启动后数秒才出现。再次执行 `speed-slayer-lite show` 会刷新 VMess 链接。
`repair-argo` 会重启 Xray 和 cloudflared，等待新的 Quick Tunnel 域名，并输出更新后的 VMess 链接。Quick Tunnel 修复后必须在客户端重新导入该链接。

VMess 链接中 `add` 默认是 `www.wto.org`，`host` 和 `sni` 仍然是当前 Tunnel 域名。这样要求 `www.wto.org` 在你的网络环境中解析到可用的 Cloudflare 边缘地址；如果客户端连不上，将 `VMESS_ADDRESS` 改为当前 Tunnel 域名：

```bash
sudo VMESS_ADDRESS='你的-tunnel.trycloudflare.com' bash install.sh show
```

如果你使用的是命名 Tunnel，也可以把 `VMESS_ADDRESS` 设为你自己的 Cloudflare 域名。`add`、`host`、`sni` 不是同一个字段，不能只把 `host/sni` 改成 `www.wto.org`。

### 客户端设置与兼容性

使用支持 **XHTTP + REALITY** 的客户端及内核，优先导入新生成的 VLESS 链接；仍只支持 TCP/WS 的客户端无法使用本节点。手动填写时：

| 字段 | 值 |
| --- | --- |
| 协议 | VLESS |
| 地址 / 端口 | VPS 地址 / 实际 `REALITY_PORT` |
| 传输 | `xhttp` |
| 模式 | `auto` |
| Path | 本次生成的 `XHTTP_PATH`，与服务端一致 |
| 安全 | `reality` |
| Flow | **留空**，本配置不使用 `xtls-rprx-vision` |
| SNI / 公钥 / short ID | 从生成链接读取，保持一致 |

链接包含 `type=xhttp&mode=auto&path=...`，路径按 URL 规则编码；不再包含 Vision flow。查看尚未迁移的旧安装时仍输出原 TCP 链接，避免把未切换的服务错误标注为 XHTTP。

实现按脚本固定的 Xray `26.3.27` 验证，参考 [Xray 官方 XHTTP + REALITY 示例](https://github.com/XTLS/Xray-examples/tree/main/VLESS-XHTTP-Reality/minimal-steal_others)与[分享链接规范](https://github.com/XTLS/Xray-core/discussions/716)。这仍是客户端直连 VPS 的方案；若整个 IP 在客户端网络不可达，换 XHTTP 或端口不会恢复 IP 可达性。

## 可选 TCP Brutal v2

普通 Lite 安装不会启用 Brutal。它适用于 **REALITY 和 SS2022 的 TCP 流量**；SS2022 UDP 和默认 QUIC Argo 隧道不受影响。保留现有节点配置、凭据及系统默认 BBR。

要求运行 systemd 的 Debian/Ubuntu、当前 Linux 内核 >= 5.10、匹配的 headers，以及加载内核模块的权限。管理器不会在容器中强装模块。

在安装了新版 Lite 的 Linux VPS 上执行：

```bash
sudo speed-slayer-lite brutal install

# 把示例 IP 换成客户端连接 VPS 时的公网 IP；100 为实际可用总带宽 Mbps
sudo speed-slayer-lite brutal add 203.0.113.5 100
sudo speed-slayer-lite brutal status

# 更新速率或删除规则
sudo speed-slayer-lite brutal add 203.0.113.5 80
sudo speed-slayer-lite brutal del 203.0.113.5

sudo speed-slayer-lite brutal disable    # 清除自有规则，停用开机恢复，保留备份
sudo speed-slayer-lite brutal uninstall  # 移除管理器；共享内核模块与备份保留
```

安装后也可以直接使用 `sudo speed-brutal ...`。旧版 Lite 没有 `brutal` 子命令时，无需重装或轮换节点凭据，可按[根 README 的 GitHub 安装命令](../README.md#安装与首次使用)安装独立管理器。

- 只接受单个 IPv4/IPv6 IP（或 `/32`、`/128`），不接受网段；存在策略路由或目标路由冲突时停止。
- 参数填写**客户端 IP**，不是 VPS IP、Argo 域名或 REALITY 伪装站。所有发往该 IP 的 TCP 连接共享速率，包括其他应用；客户端 IP 变化后要更新规则。
- 带宽支持整数 `1–100000` Mbps，应按 VPS 到客户端的实际链路填写，不采用 VPS Speedtest 上传值；过高可能增加丢包和带宽消耗。
- 添加新规则后重新建立客户端连接；修改已有规则速率可实时生效；删除后已有连接仍需关闭重连。
- 规则保存在 `/etc/speed-slayer-brutal/rules.tsv`，由 systemd 开机恢复。停用只删除本管理器的规则，失败条目保留以便重试。
- 主版和 Lite 共用管理器。卸载 Lite 会保留它，需要停用时先执行 `sudo speed-brutal disable`。

GitHub 上传时必须一并上传 **`scripts/tcp-brutal.sh`**，不能只上传 Lite 文件夹。用法、文件清单、日志排查和上游来源见[根 README 的 TCP Brutal 说明](../README.md#tcp-brutal-v2可选直连-tcp-加速)。

## 修改记录（溯源）

### 2026-10-26 — VLESS 直连改为 XHTTP + REALITY

- `install.sh`：新安装改为 XHTTP，新增随机/自定义路径和 `mode=auto`，移除 Vision flow，生成正确编码的分享链接；旧安装 `show` 保持 TCP 链接直到显式迁移。
- 新增 `migrate-xhttp`：保留原端口和凭据，备份配置、校验候选、重启服务，并在切换失败时恢复；重复执行保留路径。
- 新安装支持 `REALITY_PORT=443`，按需为 Xray 添加绑定低端口的能力；默认仍为 `30002/TCP`。
- 新增 `test-xhttp.sh`，由 `test.sh` 调用；覆盖配置/链接一致性、旧状态兼容、迁移保留、重复执行和失败恢复。
- 补充 GitHub 一键迁移、443 安装、客户端字段和重连说明；上传时同步更新 `install.sh`、两个测试文件及 README。
- Bash 语法、原有自检、13 项 XHTTP 隔离检查通过；真实 Windows Xray `26.3.27` 已校验生成的服务端、链接对应的客户端及迁移候选配置。systemd、443 实际绑定和客户端联网尚未在 Linux VPS 实测，完整结果见[根 README 修改记录](../README.md#修改记录溯源)。

### 2026-09-05 — 可选 TCP Brutal v2

- `install.sh` 新增 `brutal` 子命令，调用仓库共享管理脚本；远程下载验证固定 SHA-256。
- 新增安装、客户端 IP / Mbps 配置、状态查看、删除、停用和独立卸载说明。
- 普通 Lite 安装、REALITY/SS2022/VMess 配置及凭据生成逻辑保持原样；Brutal 不随节点安装自动启用。
- 验证结果统一记录在[根 README 修改记录](../README.md#修改记录溯源)。尚未验证 Linux VPS 的 DKMS 加载、重启恢复和实际加速效果。

## 防火墙

脚本不会修改防火墙。按你的 SSH 来源限制管理端口，并只开放：

```bash
ufw allow 30001/tcp
ufw allow 30001/udp
ufw allow 30002/tcp
```

不要开放 `30000` 和 `30003`。它们只供本机服务访问。
如果新安装时指定了 `REALITY_PORT=443`，把上面的 `ufw allow 30002/tcp` 改为 `ufw allow 443/tcp`；自定义端口同理。

## 安全设计

- Xray 和 cloudflared 使用独立低权限账户。
- systemd 服务启用基础沙箱和资源限制。
- 固定 Xray/cloudflared 版本，并校验 SHA-256。
- UUID、SS 密钥、REALITY 私钥和 Tunnel token 均为 root-only。
- 命名 Tunnel token 通过 systemd 环境传入，不出现在 cloudflared 命令行参数中。
- VMess 与 VLESS 使用不同 UUID，避免一个协议凭据泄露后同时影响另一个协议。
- REALITY 的未认证请求先进入本机 `dokodemo-door`，只允许 SNI 与 `serverNames` 完全一致的 TLS 流量访问目标站，其余进入 `blackhole`。
- 无 Nginx、无 Web 面板、无订阅 URL。
- 安装前检查端口冲突；参数只接受受限格式，不使用 `source` 或 `eval`。

更新二进制版本时，必须同时更新 `install.sh` 中对应架构的 SHA-256。

修改脚本后可执行最小自检：

```bash
bash speed-slayer-lite/test.sh
```

测试需要 Python 3、Bash、OpenSSL。默认用替身隔离 systemd/Xray，不修改系统服务；设置 `SPEED_TEST_XRAY=/path/to/xray` 可用真实内核执行配置校验，仍不会启动代理服务。Windows 可通过 PowerShell 调用 Git Bash，并用 `SPEED_TEST_PYTHON` 指定 Python 可执行文件。

这里的“防盗用”是阻止扫描器把 REALITY 的未认证回落当作通用端口转发。若 VLESS 链接、UUID、REALITY 公钥和 short ID 已泄露，对方仍可作为合法客户端使用；任何服务端配置都无法保证凭据泄露后不被使用，应及时重装或轮换凭据。

实现参考：[XTLS/Xray-examples: VLESS-TCP-REALITY (without being stolen)](https://github.com/XTLS/Xray-examples/tree/main/VLESS-TCP-REALITY%20(without%20being%20stolen))。

## Cloudflare 说明

Quick Tunnel 适合测试，不保证长期域名稳定，也不支持 SSE。长期使用请选择命名 Tunnel。

- [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- [Tunnel 防火墙要求](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
