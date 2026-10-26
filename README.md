# Speed Slayer

<p align="center">
  <img src="assets/speed-slayer-cover.jpg" alt="Speed Slayer" width="100%">
</p>

>                               VPS 网络加速 · TCP 智能调优 · Argo 隧道 · VMess WebSocket 节点生成

**Speed Slayer** 是一个面向 VPS 的网络加速与节点部署工具。它把 **XanMod / BBR v3 / TCP 智能调优**、**Cloudflare Argo Tunnel**、**VMess WebSocket 节点生成**、**诊断修复** 和 **交互式控制台** 收敛到一套清晰、可重复执行的流程里。

<p align="center">
  <strong>斩断延迟，撕开隧道，释放节点。</strong>
</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-v2.0.9-22c55e">
  <img alt="Shell" src="https://img.shields.io/badge/shell-bash-0891b2">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-f97316">
  <img alt="Status" src="https://img.shields.io/badge/status-stable-16a34a">
</p>

---

## 适合谁用

- 想给 Debian / Ubuntu VPS 做 TCP 网络优化。
- 想一键部署 Cloudflare Argo + VMess WebSocket 节点。
- 想把 TCP 调优和节点生成分开执行。
- 想要可诊断、可重装、可卸载的 VPS 网络工具。
- 使用容器小鸡 / IPv6 小鸡，需要脚本能自动降级处理。

---

## 核心能力

- **完整流程**：TCP 调优 + Argo VMess WebSocket 节点部署。
- **分流程执行**：可单独执行 TCP 调优，也可单独生成 VMess+Argo 节点。
- **XanMod / BBR v3**：自动检测内核状态，安装内核组件，并支持重启后续跑。
- **容器降级模式**：容器环境不强装宿主机内核，只应用容器内可生效配置。
- **智能 TCP buffer**：根据 Speedtest 上传带宽推荐缓存档位，并允许手动选择。
- **Lite 多协议管理**：勾选 VMess、SS2022、VLESS，选择 SNI，保留节点更新内核，支持卸载。
- **原生 Argo VMess+WS**：使用 `cloudflared + Xray + Nginx + systemd`，不依赖 ArgoX 安装链。
- **订阅输出**：生成 VMess URL、Base64、Clash、Shadowrocket、Auto 订阅。
- **交互控制台**：主菜单、子菜单、返回上级、日志查看、诊断修复一体化。
- **重复安装友好**：自动清理旧服务、旧进程、旧配置，并保留备份。
- **安全卸载**：可移除 Speed Slayer 相关内容，但不会自动删除 XanMod 内核。

---

## 前置依赖

Speed Slayer 是 Bash 脚本。新机器至少需要具备：

- `bash`
- `curl` 或 `wget`
- `ca-certificates`
- `sudo` 或 root 权限

Debian / Ubuntu 最小化系统可先执行：

```bash
apt update && apt install -y bash curl wget ca-certificates
```

如果当前不是 root，请先切换：

```bash
sudo -i
```

确认基础命令存在：

```bash
bash --version
curl --version
```

然后再执行下面的 Speed Slayer 安装命令。

---

## 快速开始

### 进入主菜单

```bash
bash <(curl -fsSL https://github.com/Benjpsusu/speed-slayer/raw/main/install.sh)
```

这条命令会安装 / 刷新 `speed` 快捷命令，并进入控制台。

如果你的环境不支持 `<(...)`：

```bash
curl -fsSL https://github.com/Benjpsusu/speed-slayer/raw/main/install.sh -o /tmp/speed-install && bash /tmp/speed-install
```

---

### 完整流程：TCP + Argo

```bash
bash <(curl -fsSL https://github.com/Benjpsusu/speed-slayer/raw/main/install.sh) --all
```

或安装后执行：

```bash
speed --all
```

---

### 只做 TCP 调优

```bash
bash <(curl -fsSL https://github.com/Benjpsusu/speed-slayer/raw/main/install.sh) --tcp
```

或安装后执行：

```bash
speed --tcp
```

---

### 只生成 VMess+Argo 节点

```bash
bash <(curl -fsSL https://github.com/Benjpsusu/speed-slayer/raw/main/install.sh) --argo
```

或安装后执行：

```bash
speed --argo
```

---

## 控制台

执行：

```bash
speed
```

主菜单：

```text
『Speed Slayer 控制台』

1. Speed Slayer TCP+Argo 🚀
2. 一键TCP调优
3. 一键Vmess+Argo 节点生成
4. 查看节点/订阅信息
5. 诊断与日志
6. 修复/清理/卸载
7. 更新
8. 多协议节点（Lite）
0. 退出
```

交互规则：

- 主菜单输入 `0`：退出脚本。
- 子菜单输入 `0`：返回主菜单。
- 查看状态、查看节点、查看日志、诊断等操作执行完后，会提示按回车返回当前子菜单。
- 如果存在续跑状态，执行 `speed` 会自动继续当前流程。

---

## 常用命令

```bash
speed                  # 无续跑状态进入主菜单；有续跑状态自动继续当前流程
speed --menu           # 安装/刷新 speed 快捷命令并进入主菜单
speed --version        # 查看版本
speed --update-self    # 更新 speed 自身

speed --all            # 完整流程：TCP 调优 + Argo 节点
speed --force-all      # 等同 speed --all
speed --tcp            # 单独执行 TCP 调优
speed --lite           # 多协议 Lite 菜单：创建、更新和卸载
speed --optimize       # 等同 speed --tcp
speed --argo           # 单独部署 Argo VMess+WS 节点
speed --continue       # 根据续跑状态继续当前流程

speed --doctor         # 全链路诊断
speed --health         # 安装后健康检查
speed --logs           # 查看日志菜单
speed --speedtest      # Ookla Speedtest 测速
speed --netcheck       # DNS / GitHub / Cloudflare / 出站连通性检测

speed --repair         # 清理残留并重装 Argo VMess+WS
speed --clear-state    # 清理重启续跑状态
speed --uninstall      # 删除 / 卸载 Speed Slayer
```

---

## 工作流程

### 完整流程

完整流程会依次执行：

1. 安装 / 刷新 `speed` 快捷命令。
2. 检测系统、内核、容器状态。
3. 如需要，安装 XanMod / BBR v3 内核组件。
4. 如果内核安装需要重启，保存续跑状态。
5. 重启后执行 `speed`，自动继续当前流程。
6. 执行 TCP 智能调优。
7. 部署 Argo VMess WebSocket 节点。
8. 生成 VMess URL 与订阅链接。
9. 执行健康检查并输出结果摘要。

### 单独 TCP 调优

单独 TCP 调优只处理网络优化，不会生成 Argo 节点。

如果 TCP 阶段安装了 XanMod 内核并要求重启，重启后执行：

```bash
speed
```

脚本只会继续 TCP 调优，不会自动进入 Argo 部署。

### 单独 Argo 节点生成

单独 Argo 流程只部署：

- `cloudflared`
- `Xray VMess + WebSocket`
- `Nginx WebSocket 反代与订阅接口`
- `systemd` 服务

不会执行 TCP 内核调优。

---

## TCP 智能调优

TCP 调优包含：

1. 检测内核、容器、SWAP、内存和网络状态。
2. 安装或识别 XanMod / BBR v3 内核。
3. 使用 Ookla Speedtest 获取上传带宽。
4. 根据带宽和内存推荐 TCP buffer。
5. 清理冲突 sysctl 配置。
6. 写入 BBR / FQ / TCP buffer / backlog / keepalive / limits / DNS 参数。
7. 应用 FQ 队列与持久化限制。
8. 输出 TCP 状态摘要。

### TCP buffer 推荐档位

| 上传带宽 | 推荐缓存 |
|---|---:|
| ≤100Mbps | 16MB |
| 100-500Mbps | 32MB |
| 500Mbps-1Gbps | 64MB |
| 1Gbps-2.5Gbps | 128MB |
| ≥2.5Gbps | 256MB |

脚本会根据内存做保护，避免小内存 VPS 因缓存过大导致压力过高。

### 手动指定带宽

```bash
SPEED_BANDWIDTH_MBPS=2000 speed --tcp
```

### 关闭自动测速

```bash
SPEED_AUTO_SPEEDTEST=0 speed --tcp
```

带宽来源说明：

- `measured`：Ookla Speedtest 实测。
- `manual`：手动指定。
- `default`：测速失败或关闭测速后的默认值。

---

## Lite 多协议一键管理

Lite 支持勾选创建 **VMess + WS + Argo、SS2022、VLESS + XHTTP + REALITY**，任意组合。未勾选的协议不创建；仅选择 VMess 时才安装 Argo。

新版文件上传 GitHub 后，在 Linux VPS 上以 root 执行：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh)
```

运行后进入菜单：`1` 创建/勾选协议、`2` 查看链接、`3` 状态、`4` 更新脚本和内核、`5` 卸载、`6` 修复 Argo、`7` 旧 VLESS 迁移到 XHTTP、`0` 退出。安装后运行 `speed-slayer-lite` 再次打开菜单；旧版用户先运行上面的一键命令，选择 `4` 更新。

勾选界面输入 `1 3` 可切换 VMess/VLESS 的选中状态，回车确认；`a` 全选、`n` 清空、`0` 取消。选 VLESS 后可以使用默认 SNI `learn.microsoft.com`，或输入自定义域名。SNI 同时用于目标站、守门规则和链接；不自动创建自建网站。

新安装 VLESS 默认 `443/TCP`，可在提示中输入其他端口；已有节点更新保留原端口。默认域名按用户要求保留，实测新版 Xray 对 `learn.microsoft.com` 也会输出封锁风险提示，可选择自定义站点。使用 443 不能保证 IP 不被封锁。

`update` 保留端口、协议、SNI、UUID、密钥和路径，下载仓库固定版本的内核并验证 SHA-256，经配置校验后切换；切换后失败时恢复旧内核与管理脚本。本版固定 Xray `26.10.21` / cloudflared `2026.10.3`，只更新已选协议需要的组件。更新会重启服务，Quick Tunnel 域名变化时需重新导入 VMess。卸载需要输入 `y` 确认，删除 Lite 服务、配置、凭据和备份，保留共享二进制及账户。

主版菜单 `8` 或 `speed --lite` 也能打开 Lite；可以从根入口直接进入：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Benjpsusu/speed-slayer/main/install.sh) --lite
```

VMess 正常但 VLESS 握手失败时，还需检查客户端启动日志中的 Xray 内核版本；服务器升级不会更新电脑端。本次同配置对照中，客户端 `25.1.30` 报 `REALITY: processed invalid connection`，`26.10.21` 联网通过。排查步骤见 [Lite 客户端兼容性说明](speed-slayer-lite/README.md#vless-单独不通检查客户端内核)。

用户于 2026-10-26 确认：将 v2rayN 从 `7.7.1` 升级到 **`7.25.6` 后，VLESS 已恢复正常连接**。官方项目：[2dust/v2rayN](https://github.com/2dust/v2rayN)；对应版本：[7.25.6 发布页](https://github.com/2dust/v2rayN/releases/tag/7.25.6)。升级后实际 Xray 内核版本未另行提供，不将界面版本等同于内核版本。

详细参数、非交互安装、SNI、备份恢复和旧节点迁移见 [Lite README](speed-slayer-lite/README.md)。根目录入口未带 `--lite` 时仍进入 TCP 调优 / Argo 主版。

### 上传 GitHub

本次应同步提交：`scripts/vps-argo-vmess-oneclick.sh`、`speed-slayer-lite/install.sh`、三个 Lite 测试脚本、两份 README、`CHANGELOG.md`，以及 `scripts/tcp-brutal.sh`、`scripts/tests/tcp-brutal-test.sh` 的删除。旧 Brutal 名称只保留在历史记录中；新入口不再提供该功能。

在仓库根目录使用 `git add -A` 可以一起暂存新增、修改和删除。上传前运行 `bash speed-slayer-lite/test.sh`；测试通过后再提交并推送到 GitHub `main`，VPS 的一键命令才能下载新版本。

---

## 容器与 IPv6 小鸡

部分容器小鸡、IPv6-only 小鸡无法安装或切换 XanMod 内核，这是宿主机限制，不是脚本本身失败。

Speed Slayer 会自动检测容器环境：

- **普通 VPS**：尝试安装 XanMod / BBR v3 内核，必要时提示重启。
- **容器环境**：跳过内核安装，进入无内核降级模式，只应用容器内可生效的优化项。

如果系统拒绝部分 sysctl 参数，脚本会保留可生效项并继续执行。

---

## VMess+Argo 输出内容

节点生成后会输出：

- VMess URL
- Base64 订阅
- Clash 订阅
- Shadowrocket 订阅
- Auto 订阅

查看节点信息：

```bash
speed --show-url
```

或进入控制台：

```text
3. 一键Vmess+Argo 节点生成
2. 查看节点/订阅信息
```

---

## 诊断与日志

常用诊断：

```bash
speed --doctor
speed --health
speed --logs
speed --netcheck
speed --speedtest
```

常见日志路径：

```text
/etc/vps-argo-vmess/install.log
/etc/vps-argo-vmess/kernel-install.log
/etc/vps-argo-vmess/tcp-optimize.log
/etc/vps-argo-vmess/speedtest.log
/etc/vps-argo-vmess/netcheck.log
/etc/argox/argo.log
/etc/argox/xray-error.log
```

XanMod 安装失败时，优先查看：

```bash
cat /etc/vps-argo-vmess/kernel-install.log
```

筛选关键日志：

```bash
grep -n "XanMod APT\|XanMod PKG\|selected suite\|no candidate\|ERR\|error\|failed" /etc/vps-argo-vmess/kernel-install.log
```

---

## 修复、重装与卸载

### 修复 Argo 安装

```bash
speed --repair
```

会清理 Argo 服务、旧进程和旧配置，然后重新部署 VMess+WS。

### 清理续跑状态

```bash
speed --clear-state
```

适合在中断安装、误进入续跑状态、想回到主菜单时使用。

### 卸载 Speed Slayer

```bash
speed --uninstall
```

会清理：

- `/usr/local/bin/speed`
- `/etc/vps-argo-vmess`（备份为 `.bak.<timestamp>`）
- `/etc/argox`（备份为 `.bak.<timestamp>`）
- `argo.service` / `xray.service`
- Speed Slayer 写入的 sysctl、systemd limits、DNS、IPv6 配置

注意：**不会自动卸载 XanMod 内核本身**，避免误删系统内核导致机器无法启动。

卸载确认默认为 `N`，必须明确输入 `y` 或 `yes` 才会执行。

---

## 更新

推荐：

```bash
speed --update-self
```

如果本机脚本损坏，可重新拉取安装入口：

```bash
curl -fsSL https://github.com/Benjpsusu/speed-slayer/raw/main/install.sh -o /tmp/speed-install && bash /tmp/speed-install
```

---

## CDN 优选建议

节点生成后，建议在本地运行 CloudflareSpeedTest，选择延迟更低、速度更稳的 CDN IP：

<https://github.com/XIU2/CloudflareSpeedTest>

---

## 鸣谢

特别感谢 **@Eric86777** 的 TCP 调优思路与实践参考。

- NodeSeek 帖子：<https://www.nodeseek.com/post-704739-1>
- 项目仓库：<https://github.com/Eric86777/vps-tcp-tune>

Speed Slayer 的 TCP 调优方向参考了他的思路，并在此基础上做了产品化控制台、续跑机制、诊断修复、Argo VMess WebSocket 部署与订阅输出等整合。

---

## 版本

当前脚本版本：`v2.1.0`

### v2.1.0

- 移除 TCP Brutal 的功能模块、测试和主版/Lite 入口。
- Lite 新增协议勾选、默认/自定义 SNI、更新及卸载菜单；主版通过 `--lite` 或菜单 8 进入。
- 新安装 VLESS 默认 TCP 443；更新保留旧节点配置和凭据，固定并验证内核版本。

### v2.0.9

- 新增可选 TCP Brutal v2 共享管理器，主版与 Lite 均可调用。
- 默认保留 BBR/FQ；按客户端单 IP 管理规则、开机恢复、状态验证和清理。
- 新增用法、GitHub 上传说明及修改溯源约定。

## 修改记录（溯源）

后续每次修改都应追加记录，包含日期、目的、文件和验证情况；具体约定见 [AGENTS.md](AGENTS.md)。历史记录不得覆盖，尚未运行的检查不得标记为通过。

### 2026-10-26 — 用户确认升级 v2rayN 7.25.6 后 VLESS 恢复

- **目的与结果**：补全前一条 VLESS 排查记录的用户端验证结果。用户原用 v2rayN `7.7.1`、Xray `25.1.30`，VMess 正常而 VLESS 不通；用户升级 v2rayN 至 **`7.25.6` 后明确确认 VLESS 已通**。此前“尚待确认”是排查当时的状态，保留用于溯源。
- **官方来源**：[2dust/v2rayN 项目](https://github.com/2dust/v2rayN)、[7.25.6 发布页](https://github.com/2dust/v2rayN/releases/tag/7.25.6)。客户端升级与服务端升级需要分别处理。
- **涉及文件**：本 README 与 `speed-slayer-lite/README.md`，在用法和修改记录中补充恢复确认及官方链接。本次只修改文档，未操作服务器或修改安装脚本。
- **验证与边界**：恢复结果来自用户实际重连确认；此前同配置 Xray `25.1.30` 失败、`26.10.21` 通过的独立测试仍保留。用户未提供升级后的内核版本，不将 v2rayN `7.25.6` 推断为某个固定 Xray 版本。文档差异及 UTF-8/LF 检查通过；未重跑运行时测试，未验证长期稳定性或其他客户端组合。

### 2026-10-26 — VLESS XHTTP 旧客户端内核握手失败排查

- **目的**：排查 VMess 正常、VLESS 不通。用户客户端界面为 v2rayN `7.7.1`，日志显示实际内核为 Xray `25.1.30`；VPS 已运行 `26.10.21`，VLESS 使用旧安装保留的 `30002/TCP`、XHTTP + REALITY 与 `learn.microsoft.com`。
- **检查**：Xray/Argo 服务正常、NTP 已同步、本机防火墙未阻断；分享链接中的 UUID、端口、公钥、short ID、Path 与服务端一致，目标站 TLS 1.3 / h2 协商成功。服务器内临时客户端访问 HTTPS 测试地址得到 204/200。
- **版本对照**：同一 Windows 环境、同一当前链接、同一物理网卡出口，Xray `25.1.30` 的两次 HTTPS 请求均失败，日志为 `REALITY: processed invalid connection`；只替换临时测试内核为 `26.10.21` 后得到 gstatic HTTP 204、Cloudflare HTTP 200，出口与该 VPS 的 IPv6 一致。旧版官方归档已核对 SHA-256，新版使用此前校验过的官方二进制。该结果针对本次节点组合，不推断所有旧版 REALITY 节点均不可用。
- **测试边界**：初始默认路由经过另一 TUN 代理时超时，最终对照仅给临时测试连接绑定物理网卡，未修改系统路由或用户代理设置。Windows curl 另遇离线证书吊销查询错误，最终两版本统一使用启用证书与主机名验证的 Python ssl 完成对照。
- **涉及文件与操作**：只更新两份 README，补充客户端内核版本排查说明；VPS 写入权限 `0600` 的 `/etc/speed-slayer-lite/diagnostics/20261026-vless-client-compatibility.txt`。未修改 VPS 配置、节点凭据或已安装内核，未重启 Xray/Argo，临时测试进程与含凭据配置已清理。
- **处理建议与未验证项**：客户端更新 Xray、确认启动日志为 `26.10.21`，迁移后重新导入当前 XHTTP 链接；服务器更新命令不会更新电脑端。用户自己的客户端更新及恢复情况尚待确认，未验证长期稳定性。

### 2026-10-26 — v2.1.0：移除 Brutal，增加多协议交互和保留配置更新

- **目的**：按用户要求删除 Brutal，安装时勾选协议，VLESS 可选择默认 `learn.microsoft.com` 或自定义 SNI，一键命令提供更新与卸载。
- **协议与交互**：Lite 默认显示菜单，编号切换 `[ ]`/`[x]`、回车确认。只生成所选协议的入站、凭据及链接，仅选 VMess 时安装和启动 cloudflared。自定义 SNI 同步 REALITY 目标、守门规则和客户端链接；新安装默认 443，可输入其他端口，更新不改旧端口。
- **更新与卸载**：新增 `update`，下载仓库管理脚本、使用其固定版本/摘要，备份后校验候选内核，切换并重启，失败时恢复旧内核和脚本；配置、协议、SNI、UUID、密钥、路径保持原样。旧 state 缺少协议标记时兼容全部三种。卸载默认取消，确认后仅删除 Lite 服务、配置、凭据和本目录备份，保留共享二进制与系统账户。
- **文件**：修改 `scripts/vps-argo-vmess-oneclick.sh`（v2.1.0、`--lite`、菜单 8）、`speed-slayer-lite/install.sh`、`speed-slayer-lite/test.sh`、两份 README 和 CHANGELOG；新增 `speed-slayer-lite/test-manage.sh`；删除 `scripts/tcp-brutal.sh` 与 `scripts/tests/tcp-brutal-test.sh`。Brutal 的历史记录保留；本次不清理其他机器上过去独立安装的模块或规则。
- **版本来源**：固定官方 [Xray 26.10.21](https://github.com/XTLS/Xray-core/releases/tag/v26.10.21) 和 [cloudflared 2026.10.3](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.3)。已实际下载两者 Linux amd64/arm64 共四份发布文件，SHA-256 均与脚本固定值和 GitHub Release 元数据一致。
- **验证**：6 个相关 Bash 文件语法检查、主版帮助入口和 Git 空白检查通过。原有 Lite 自检、13 项 XHTTP 隔离检查、23 项新增管理检查通过，使用真实 Windows Xray `26.10.21` 校验服务端、客户端和候选配置；覆盖七种协议组合、默认/自定义 SNI、仅检查所选端口、旧状态兼容、重复更新、下载/配置/组件校验失败、重启/运行状态/节点信息/隧道域名失败后的恢复、卸载默认取消及清理范围、VLESS 单独新装。下载和 systemd 使用替身，四份真实 Linux 发布文件另行验证摘要及 Xray 归档结构。
- **未验证**：未在用户 VPS 执行本版真实安装、更新、卸载或更换运行中的内核；Linux systemd、Linux ARM64 新内核联网及长期稳定性尚未实测。已完成的本地测试不等同于生产升级。

### 2026-10-26 — Xray 26.10.21 升级兼容性评估

- **目的**：核对现有固定版本 `26.3.27` 与新版的兼容性，评估 VMess/WS、SS2022 和 XHTTP + REALITY 是否还能加载。
- **上游信息**：截至本次检查，[官方 Latest 为 v26.10.21](https://github.com/XTLS/Xray-core/releases/tag/v26.10.21)，发布于 2026-10-21，GitHub API 标记 `prerelease=false`。发布说明包含证书信任链相关紧急安全更新，建议尽快升级；完整累计变更说明尚待上游补充。该版本源码仍保留本脚本使用的 VMess、WebSocket、SS2022 和旧 `clients` 字段兼容。
- **实际检查**：下载官方 Windows amd64 发布包并核对 GitHub Release API 提供的 SHA-256：`fc58c39ee2f2717b4c54d28d374362389e5319b20ae44aea76ea45a5243ec827`。以真实 `26.10.21` 内核运行 `speed-slayer-lite/test-xhttp.sh`，13 项检查通过，包括完整服务端配置、链接重建的 XHTTP 客户端配置、迁移候选的 `run -test`，以及模拟服务失败时的恢复。
- **涉及文件与边界**：更新本 README 和 Lite README 的评估记录；未修改安装脚本的版本或摘要，未替换 VPS 正在运行的内核。Lite 不自动跟随上游版本，目前也没有独立的内核升级命令；`migrate-xhttp` 只负责配置迁移，不能代替内核升级。
- **后续升级要求**：更新脚本时需同步固定版本与 Linux amd64/arm64 发布包摘要；已有 VPS 应先备份内核和配置，用候选内核校验，再替换、重启并验证三种节点，失败时恢复。当前 `PartOf=xray-lite.service` 会令 Argo 随 Xray 重启，Quick Tunnel 域名可能变化，届时需刷新并重新导入 VMess 链接。
- **未验证**：新版 Linux ARM64 在该 VPS 上的实际启动、三协议联网、客户端版本交互及长期稳定性；本地配置与隔离检查通过不等于已完成生产升级。

### 2026-10-26 — 修复 VMess 因服务器时间漂移而无法连接

- **目的与原因**：排查 Lite 中其他节点可用、只有 VMess 不通的问题。Xray 日志明确报 `invalid user > invalid timestamp, perhaps unsynchronized time`；服务器未安装运行中的 NTP 服务，分别与 Oracle、Cloudflare、Google NTP 比对，UTC 时间慢约 139.4 秒。VMess 的 UUID、WebSocket 路径与导出链接一致，Argo 隧道已正常注册。
- **服务器操作**：从 Debian 已配置的软件源安装 `chrony`，启用服务及开机启动，恢复自动校时；未重启 Xray/cloudflared，未改动节点凭据、端口或 Quick Tunnel 域名。诊断和修复记录保存在服务器 `/etc/speed-slayer-lite/diagnostics/20261026-vmess-time.txt`，权限 `0600`。
- **涉及文件**：本 README、`speed-slayer-lite/README.md`，新增时间同步排查说明；服务器新增 chrony 软件包及其默认配置。本次未修改安装脚本，不会使以后新装的 VPS 自动获得 NTP 服务。
- **验证**：`timedatectl` 显示 `NTP=yes`、`NTPSynchronized=yes`，`chronyc tracking` 显示 `Leap status: Normal`。用现有 VMess 分享链接构造临时 Xray 客户端，经过 Cloudflare Tunnel 请求两个 HTTPS 测试地址，分别得到 HTTP 204 和 200，出口 IP 与服务器一致；临时客户端和测试文件随后清理。用户重新连接原节点后确认恢复正常。
- **未验证**：VPS 重启后的持续校时与长期漂移；本次通过的是当前连接及当前时间同步状态，不代表已进行长期稳定性测试。其他历史验证记录保持原样。

### 2026-10-26 — Lite 直连节点切换为 XHTTP + REALITY

- **目的**：将 Lite 的 VLESS + TCP + REALITY + Vision 改为 VLESS + XHTTP + REALITY，并为已有安装提供保留凭据的迁移入口。
- **配置与链接**：`speed-slayer-lite/install.sh` 生成 `network=xhttp`、`mode=auto` 和独立随机 Path，移除本组合的 Vision flow；链接包含正确编码的 `type=xhttp`、`mode`、`path`。旧安装未迁移时仍输出 TCP 链接。
- **迁移**：新增 `migrate-xhttp`，备份配置/状态/脚本/节点信息，经 Xray 校验后切换，服务启动失败时恢复；保留原端口、UUID、REALITY 密钥、其他节点和既有守门规则，重复迁移保留路径。
- **端口**：默认保留 `30002/TCP`，新安装允许 `REALITY_PORT=443`；低权限 Xray 服务按需获得 `CAP_NET_BIND_SERVICE`，继续检查端口冲突。
- **测试与文档**：新增 `speed-slayer-lite/test-xhttp.sh` 并接入 `test.sh`；主 README、Lite README 和 CHANGELOG 记录一键安装/迁移、443、客户端字段及 GitHub 上传要求。
- **验证**：Bash 语法、原有 Lite 自检及新增 13 项 XHTTP 隔离检查通过。使用校验过发布包 SHA-256 的 Windows Xray `26.3.27`，实际执行了生成的服务端配置、从分享链接重建的客户端配置、迁移候选的 `run -test`；覆盖路径编码、443 服务配置、旧状态兼容、凭据保留、重复迁移、配置拒绝、服务重启失败和输出链接失败后的恢复。systemd 使用替身，不修改本机服务；Git 空白检查和原 Brutal 模块摘要检查通过。
- **未验证**：Linux systemd 下的实际 443 绑定、真实客户端 XHTTP + REALITY 连接、VPS 网络可达性和抗封锁效果。测试不代表 IP 封锁可以通过换传输解除。

### 2026-09-05 — v2.0.9：接入 TCP Brutal v2

- **目的**：为 Lite 的 REALITY / SS2022 TCP 直连提供可选的按客户端 IP 加速，主版复用同一管理能力。
- **新增**：`scripts/tcp-brutal.sh`（固定 v2.0.0 与源码包 SHA-256、环境检测、规则管理、systemd 开机恢复、状态检查、失败恢复与自有规则清理）。
- **入口**：`scripts/vps-argo-vmess-oneclick.sh` 新增 `--brutal` 和 TCP 子菜单，版本升为 v2.0.9；`speed-slayer-lite/install.sh` 新增 `brutal` 子命令。两个入口下载共享模块时校验摘要。
- **边界**：只支持单个 IPv4/IPv6 客户端地址，拒绝策略路由和目标路由冲突；不自动更改全局 BBR、Argo 或节点凭据；共享模块独立管理和卸载。
- **文档与后续约定**：本 README 和 Lite README 补充可复制的安装、配置、停用命令；新增 `AGENTS.md` 要求每次修改记录溯源。
- **验证**：通过 Bash 语法检查、`scripts/tests/tcp-brutal-test.sh` 的 25 项隔离检查及 Lite 原有自检；覆盖 IPv4/IPv6、非法参数、重复更新、规则添加失败恢复、重启规则重放、路由冲突、外部规则保护及两版入口调用。已下载并核对上游源码包 SHA-256 与归档结构。隔离测试使用替身命令，不修改宿主机网络。
- **未验证**：Linux VPS 上的真实 DKMS 编译/加载、systemd 重启恢复、实际吞吐与丢包表现；本地 Windows 检查不能替代这些实机验证。

### v2.0.8

- NAT / LXC 环境自动跳过 Ookla Speedtest，避免卡在 `Cannot read from socket / Latency test failed`；改为手动选择上行带宽档位。
- 节点名默认改为 `国家代码-主机名-vmess-ws-argo`，例如 `US-tmobile-6BjoBc-vmess-ws-argo`；仍可用 `NODE_NAME=...` 覆盖。
- 控制台主页新增“查看节点/订阅信息”入口，节点信息不再藏在二级菜单里。

---

## License

MIT or repository default license. See repository files for details.
