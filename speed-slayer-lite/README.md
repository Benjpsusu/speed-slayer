# Speed Slayer Lite

按需创建以下节点，可任选一种或多种：

- VMess + WebSocket + Cloudflare Tunnel
- Shadowsocks 2022（`2022-blake3-aes-128-gcm`）
- VLESS + XHTTP + REALITY（随机路径、`mode=auto`、Flow 留空）

未勾选的协议不生成入站或节点链接。只有勾选 VMess 才下载 cloudflared、创建其账户/配置并启动 Argo。不安装 Nginx，不提供 HTTP 订阅。

## 一键打开管理菜单

支持 Debian 11+、Ubuntu 20.04+，amd64/arm64，需要 systemd。以下命令在 **Linux VPS 上以 root 执行**；普通用户先运行 `sudo -i`。

先把新版文件上传到 GitHub，然后执行：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh)
```

新安装和已有安装都显示菜单：

```text
1. 创建节点（勾选协议 / 选择 SNI）
2. 查看节点链接
3. 查看运行状态
4. 更新脚本和内核（保留节点配置）
5. 卸载 Lite 节点
6. 修复 VMess / Argo 隧道
7. 旧 VLESS TCP 节点迁移到 XHTTP
0. 退出
```

安装成功后运行 `speed-slayer-lite` 即可再次打开菜单。旧版快捷命令尚未包含菜单时，先运行上面的 GitHub 一键命令，选择 `4` 更新。

主版也可执行 `speed --lite`，或在 `speed` 主菜单选择 `8. 多协议节点`。根目录 `install.sh` 默认仍进入主版；带 `--lite` 可直接打开本菜单。

## 勾选协议和设置 SNI

菜单选 `1` 后显示：

```text
[ ] 1. VMess + WebSocket + Argo
[ ] 2. Shadowsocks 2022
[ ] 3. VLESS + XHTTP + REALITY

a. 全选  n. 清空  0. 取消  回车：确认选择
```

输入编号切换 `[ ]` / `[x]`，可一次输入 `1 3`；选好后按回车。初始不勾选，至少选择一个协议。

选中 VLESS 才会询问 SNI：

- `1` 或直接回车：使用 `learn.microsoft.com`。
- `2`：输入自定义域名，例如 `www.example.com`；不要填写 `https://`、端口或路径。
- 自定义 SNI 同步用于 REALITY 的 `serverNames`、目标站、SNI 守门规则和客户端链接。这里继续使用外部目标站，不自动创建自建网站。

随后询问 VLESS 的 TCP 端口，新安装默认 `443`，可改为 `1024–65535` 的其他端口。443 已占用时安装停止，不覆盖其他服务。现有节点更新时保持原端口，不会把旧的 30002 自动改成 443。

SNI 输入会检查域名格式，但不代表目标站的 TLS 1.3/HTTP/2 支持及连通性已验证。实测 Xray `26.10.21` 会对默认的 `learn.microsoft.com` 输出封锁风险警告；本脚本按用户选择保留此默认值，也允许自定义。443 和自定义 SNI 都不能保证避免 IP 封锁。

已有安装不能在更新时重新勾选协议；更新保留现有节点。若要重新创建一组节点，需要先卸载，原凭据会被删除。

## 更新与卸载

选择菜单 `4`，或执行：

```bash
sudo speed-slayer-lite update
```

更新先下载仓库新版管理脚本，再由新版脚本下载它固定的内核版本，并校验对应架构的 SHA-256。本版固定 **Xray 26.10.21、cloudflared 2026.10.3**；仅在安装了 VMess 时更新 cloudflared。不会自动追随上游未经本仓库固定的 Latest。

- 将旧内核、配置、state、管理脚本和节点信息备份到 `/etc/speed-slayer-lite/backup-update-<时间>.<随机后缀>/`，目录权限 `0700`。
- 候选内核先执行配置校验，通过后替换二进制、更新管理脚本并重启相关服务。
- 保留协议选择、端口、SNI、UUID、密钥和路径；不会把旧 TCP/Vision 配置自动改为 XHTTP。
- 下载/校验失败时不切换；切换后服务启动、获取 Quick Tunnel 域名或节点信息生成失败，会尝试恢复旧内核和管理脚本。自动恢复失败会报告备份位置。
- 重启会短暂断开连接，Quick Tunnel 域名可能改变。更新完成后查看输出；域名变化时重新导入 VMess 链接。恢复旧内核后域名也可能变化，应运行 `show` 刷新。

选择菜单 `5` 卸载，需要输入 `y` 确认，直接回车取消。也可以：

```bash
sudo speed-slayer-lite uninstall
```

卸载停止并删除 Lite 服务、配置、凭据、快捷命令，以及 Lite 目录内的更新/迁移备份。共享的 `/usr/local/bin/xray`、`cloudflared` 二进制和系统账户保留。无人值守卸载可以显式添加 `--yes`。

## 端口与防火墙

| 端口默认值 | 用途 | 是否放行公网 |
| --- | --- | --- |
| `127.0.0.1:30000/TCP` | 已选 VMess 的 WebSocket 源站 | 不放行 |
| `30001/TCP+UDP` | 已选 SS2022 | 放行 |
| `443/TCP` | 新建 VLESS XHTTP + REALITY | 放行；已安装节点用原端口 |
| `127.0.0.1:30003/TCP` | 已选 VLESS 的 REALITY 守门入站 | 不放行 |

只检查所选协议需要的端口，且这些端口不能重复。脚本不修改系统防火墙或云安全组；按实际选择开放公网端口。Xray 以独立账户运行，只有 VLESS 使用 443 时才授予低端口绑定能力。

VMess 经 Cloudflare 接入时客户端使用 443，服务器源站端口无需暴露。cloudflared 需要到 Cloudflare 的出站连接，详见[官方防火墙要求](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)。

## 命令行与自动安装

不带参数进入菜单。显式 `install` 在交互终端且未设置 `PROTOCOLS` 时也会显示勾选；自动化建议始终明确设置 `PROTOCOLS`。非交互 `install` 未指定协议时，为兼容旧用法仍选择全部三种协议。

只安装 VLESS，使用自定义 SNI 和端口：

```bash
PROTOCOLS=vless REALITY_SERVER_NAME='www.example.com' REALITY_PORT=8443 \
  bash install.sh install
```

安装 VMess 和 SS2022，使用命名 Tunnel：

```bash
PROTOCOLS=vmess,ss2022 ARGO_MODE=token \
  ARGO_TOKEN='你的 Tunnel token' ARGO_DOMAIN='你的隧道域名.example.com' \
  bash install.sh install
```

命名 Tunnel 的 Public Hostname 服务地址应指向 `http://127.0.0.1:30000`（自定义 `VMESS_PORT` 时相应修改）。未选 VMess 时忽略 Argo 参数。默认 Quick Tunnel 会自动分配临时域名。

其他新安装参数：`VMESS_PORT`、`SS_PORT`、`REALITY_GUARD_PORT`、`VMESS_ADDRESS`、`XHTTP_PATH`。XHTTP 路径默认随机生成；自定义需以 `/` 开头，后接 1–128 个字母、数字、`/`、`_` 或 `-`。更新命令始终使用已安装配置。

```bash
sudo speed-slayer-lite show
sudo speed-slayer-lite status
sudo speed-slayer-lite repair-argo
sudo speed-slayer-lite migrate-xhttp
```

`show` 只输出已安装协议的链接，凭据文件 `/etc/speed-slayer-lite/client-info.txt` 权限为 `0600`。未获取到临时域名时显示等待提示，不生成含占位域名的 VMess 链接。

`repair-argo` 仅适用于已安装 VMess 的节点，会重启相关服务并刷新链接；完成后重新导入 VMess。VMess 的连接地址默认 `www.wto.org`，Host/SNI 为隧道域名；若本地网络无法连接该地址，可将连接地址改为实际隧道域名，Host/SNI 保持匹配：

```bash
sudo VMESS_ADDRESS='你的隧道.trycloudflare.com' speed-slayer-lite show
```

## 旧 VLESS TCP 节点迁移到 XHTTP

菜单 `7` 或 `migrate-xhttp` 会保留端口和凭据，备份、校验配置后切换 VLESS 传输，失败时恢复。没有安装 VLESS 时拒绝迁移。也可以使用 GitHub 新脚本执行：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh) migrate-xhttp
```

重复迁移保留路径；旧安装未迁移时 `show` 继续输出 TCP/Vision 链接。迁移不会升级内核，也不会新增更早旧版中缺少的守门入站。完成后重新导入 VLESS；如果 Argo 临时域名变化，也重新导入 VMess。

客户端需要支持 XHTTP + REALITY：传输 `xhttp`、模式 `auto`、Flow 留空，Path/SNI/公钥/short ID 均使用生成链接中的值。

## VLESS 单独不通：检查客户端内核

v2rayN 的界面版本与实际 Xray 内核版本是两回事，应查看启动日志中的 `Xray ...`。VPS 上执行 `speed-slayer-lite update` 只更新服务器，不会更新电脑客户端。

2026-10-26 实测：服务器 Xray `26.10.21`，同一 XHTTP + REALITY 链接、同一网络线路下，客户端 `25.1.30` 报 `REALITY: processed invalid connection`，替换为 `26.10.21` 后两个 HTTPS 请求分别返回 204/200。这是当前组合的验证结果，不是所有旧版节点的通用结论。

用户于 2026-10-26 确认：将 v2rayN 从 `7.7.1` 升级到 **`7.25.6` 后，VLESS 已恢复正常连接**。官方项目：[2dust/v2rayN](https://github.com/2dust/v2rayN)；对应版本：[7.25.6 发布页](https://github.com/2dust/v2rayN/releases/tag/7.25.6)。升级后实际 Xray 内核版本未另行提供，不将界面版本等同于内核版本。

1. 在 v2rayN 的“检查更新”中更新 **Xray 内核**，重启后确认日志显示 `26.10.21`（本次验证版本）。旧客户端无法更新时，从 [v2rayN 官方发布页](https://github.com/2dust/v2rayN/releases/latest) 获取适合系统的新版，保留旧目录作为备份；安装后仍应确认并更新内核版本。
2. 在 VPS 执行 `speed-slayer-lite show`，重新导入当前 VLESS 链接，尤其是刚从 TCP/Vision 迁移到 XHTTP 的节点。核对 `type=xhttp`、`mode=auto`、Flow 留空，以及端口、Path、SNI、公钥和 short ID。
3. 确认测试连接没有经过另一个代理或 TUN。此类叠加可能使测试超时，应区分代理路径与直连路径；不要仅凭一次 TCP 端口测试判定 VLESS 已可用。
4. 若仍不通，保留实际连接错误日志，检查 VPS 的监听、防火墙/云安全组和服务端日志。单独的“测试完成”并不能说明连接成功或定位原因。

v2rayN `7.7.1` 的[官方链接解析代码](https://github.com/2dust/v2rayN/blob/7.7.1/v2rayN/ServiceLib/Handler/Fmt/BaseFmt.cs)已支持 XHTTP；不能仅凭界面版本断言不支持该传输。本次没有为了排查而改动服务端端口、SNI、密钥或重启现有服务。

## 验证与维护

在仓库内运行：

```bash
bash speed-slayer-lite/test.sh
```

需要 Bash、Python 3、OpenSSL。默认隔离系统服务和下载；设置 `SPEED_TEST_XRAY=/path/to/xray` 可用真实内核校验配置。Windows 可通过 PowerShell 7 调用 Git Bash，设置 `SPEED_TEST_PYTHON` 指向 Python 可执行文件。测试不操作真实 systemd 服务。

上传 GitHub 时同步上传主版脚本、Lite 安装脚本、`test.sh`、`test-xhttp.sh`、`test-manage.sh`、两份 README 和 CHANGELOG，并提交旧 Brutal 脚本及其测试文件的删除。历史修改记录保留。

### VMess 单独不通：检查系统时间

如果 Argo 已连接，其他节点正常，但 VMess 日志出现 `invalid user > invalid timestamp, perhaps unsynchronized time`，先检查服务器和客户端的系统时间。VMess 认证依赖 UTC 时间；[Xray 官方文档](https://xtls.github.io/config/inbounds/vmess.html)要求时间误差在 120 秒以内。修改显示时区不能修复时钟漂移。

在 Linux VPS 上检查：

```bash
sudo timedatectl status
sudo journalctl -u xray-lite -n 50 --no-pager
```

若已有对时服务，修复现有服务并确认同步成功；若没有安装对时服务，Debian/Ubuntu 可安装并启用 chrony：

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends chrony
sudo systemctl enable --now chrony
sudo chronyc tracking
sudo timedatectl status
```

首次启动需要等待对时；确认 `Leap status: Normal` 和 `System clock synchronized: yes`，不能只看 chrony 进程是否启动。客户端也应开启系统自动对时，然后重新连接原 VMess 节点。仅修复时间无需重启 Xray/Argo，也无需换链接。

2026-10-26 实机排查中，服务器慢约 139.4 秒且没有 NTP 服务，恢复 chrony 后原 VMess 链接通过完整联网测试，用户确认恢复。Lite 安装脚本目前不自动配置 NTP，新服务器部署前应先确认自动校时可用。


## 安全与 Cloudflare 说明

配置和凭据只保存在服务器，REALITY 私钥不写入分享链接；Xray/cloudflared 使用独立低权限账户，服务保留系统沙箱限制。SNI 守门用于限制未认证请求的回落目标，不能阻止已经拿到完整节点凭据的人使用节点。

Quick Tunnel 适合测试，域名可能随重启变化。需要稳定域名时使用命名 Tunnel；参考 [Quick Tunnels 官方说明](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)。

## 修改记录（溯源）

### 2026-10-26 — 用户确认 v2rayN 7.25.6 恢复 VLESS

- 用户将 v2rayN 从 `7.7.1` 升级到 **`7.25.6` 后确认 VLESS 已恢复正常连接**，补全上一条排查记录中的待确认结果；原排查历史保留。
- 官方项目：[2dust/v2rayN](https://github.com/2dust/v2rayN)；对应版本：[7.25.6](https://github.com/2dust/v2rayN/releases/tag/7.25.6)。客户端内核与界面版本需分别核对，升级后实际内核版本未另行提供。
- 两份 README 的用法与溯源记录已同步。本次仅修改文档，未操作服务器或修改安装脚本；文档差异与 UTF-8/LF 检查通过，未重跑运行时测试。当前恢复由用户实测确认，长期稳定性及其他版本组合未验证。

### 2026-10-26 — VLESS 旧客户端内核握手失败对照

- 排查 VMess 可用、VLESS 不通：VPS 为 Xray `26.10.21`，客户端日志显示 `25.1.30`。服务、NTP、端口与链接参数均已核对；服务器本机 VLESS 两次 HTTPS 请求通过。
- 同配置、同物理网卡的外部测试中，客户端 `25.1.30` 报 `REALITY: processed invalid connection`；只换临时内核为 `26.10.21` 后返回 HTTP 204/200，出口与 VPS 一致。最终对照使用 Python ssl 验证证书和主机名，并排除另一 TUN 代理与 Windows curl 吊销查询对结果的干扰。
- 两份 README 新增内核检查、更新及迁移后重导链接的说明；服务器保存 `diagnostics/20261026-vless-client-compatibility.txt`，权限 `0600`。未修改安装脚本、VPS 配置、凭据或运行中的内核，未重启 Xray/Argo；临时测试进程与含凭据配置已清理。
- 建议客户端更新并确认 Xray `26.10.21`；用户自己的客户端恢复尚待确认，长期稳定性未验证。完整过程及边界见根 README。

### 2026-10-26 — 协议勾选、SNI 选择、更新卸载菜单，移除 Brutal

- 默认进入管理菜单，支持勾选任意协议组合；仅选择 VMess 时部署 cloudflared，未选协议不生成配置和链接。旧 state 未记录协议时兼容原来的全协议安装。
- VLESS SNI 提供默认 `learn.microsoft.com` 和自定义输入；同步目标站、守门规则与分享链接。新安装默认 TCP 443，可交互修改，已有节点更新保留端口。
- 新增 `update`：由仓库最新版管理脚本固定内核版本，备份、校验候选、替换、重启，失败时恢复旧内核/脚本；保留节点配置和凭据。固定 Xray `26.10.21`、cloudflared `2026.10.3`，核对 amd64/arm64 下载摘要。
- 新增卸载确认，取消或输入结束不会删除节点；去掉 Lite 的 Brutal 命令，主版同步移除入口并新增 `--lite` / 菜单 8。历史记录不删除。
- 涉及 `install.sh`、新增 `test-manage.sh`、测试入口及两份 README；完整文件清单见根 README。
- 验证：Bash 语法、原有 Lite 自检、13 项 XHTTP 检查及 23 项管理检查通过；用真实 Windows Xray `26.10.21` 校验七种协议组合和更新候选，覆盖故障恢复、旧状态、交互和卸载范围。真实 Linux amd64/arm64 的四份发布文件摘要已核对，下载和 systemd 流程在测试中使用替身。未在真实 VPS 执行本版安装、更新或卸载，也未测试新版 Linux 内核的实际联网和长期运行。

### 2026-10-26 — 新版 Xray 兼容性评估

- 核对[官方 v26.10.21 发布说明](https://github.com/XTLS/Xray-core/releases/tag/v26.10.21)：截至本日它是 Latest，含证书相关安全修复；当前脚本仍固定 `26.3.27`，不会自动跟随上游更新。
- 校验官方 Windows 发布包摘要后，用真实 `26.10.21` 内核执行 `test-xhttp.sh`，13 项检查通过；完整服务端（含 VMess/WS、SS2022、XHTTP + REALITY）、XHTTP 客户端和迁移候选配置均通过校验。服务操作仍使用替身。
- 本次只更新两份 README，未升级服务器或修改安装版本；新版 Linux ARM64 实际联网与长期稳定性尚未验证。
- 现有脚本没有独立的内核升级命令，`migrate-xhttp` 不更新内核。正式升级需备份、校验候选、同步版本与摘要、重启后逐节点验证并准备恢复；Quick Tunnel 域名可能随重启变化。完整结果见[根 README 修改记录](../README.md#修改记录溯源)。

### 2026-10-26 — VMess 时间漂移故障排查与恢复

- 排查发现服务器 UTC 慢约 139.4 秒、未启用对时服务，Xray 拒绝 VMess 请求并报 `invalid timestamp`；UUID、WS 路径和 Argo 隧道均正常。
- 在服务器安装并启用 chrony 后完成时间同步；Xray/cloudflared 进程、节点凭据和域名保持原样。
- 用原链接构造临时 Xray 客户端，经 Cloudflare 隧道访问 HTTPS 测试地址得到 HTTP 204/200；用户重连后确认恢复正常。临时客户端已结束，测试文件已清理。
- 本 README 新增诊断与校时操作，根 README 同步记录服务器变更、验证结果和未验证项；安装脚本未修改，后续新装仍需自行确认 NTP。
- 已验证当前时间同步和 VMess 联网；未进行 VPS 重启恢复或长期稳定性测试。完整记录见[根 README 修改记录](../README.md#修改记录溯源)。

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
