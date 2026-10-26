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
- **可选 TCP Brutal v2**：按客户端 IP 为直连 TCP 配置总带宽，支持开机恢复、状态检查和规则清理；默认流程不安装、不启用。
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
4. 诊断与日志
5. 修复/清理/卸载
6. 更新
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
speed --brutal         # TCP Brutal 可选管理菜单（直连 TCP）
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

## Lite 一键部署：VLESS + XHTTP + REALITY

Lite 的 VLESS 直连节点已改为 **XHTTP + REALITY**，同时部署 VMess + WS + Argo 和 SS2022。默认端口为 `30002/TCP`；新安装可指定 `REALITY_PORT=443`。完整说明见 [Lite README](speed-slayer-lite/README.md)。

先将新版文件上传到 GitHub；以下命令在 Linux VPS 上以 root 执行。

全新安装：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh)
```

已有 Lite TCP / Vision 节点，保留原端口与凭据切换为 XHTTP：

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install.sh) migrate-xhttp
```

新安装使用 443 时，在安装命令前加 `REALITY_PORT=443`，放行 `443/TCP`，并确保无其他服务占用。迁移命令保持原端口，不会自动移到 443。迁移先备份和校验配置，再重启 Xray，失败时恢复；完成后必须重新导入 VLESS 链接，Quick Tunnel 域名变化时也重新导入 VMess 链接。

客户端需支持 XHTTP + REALITY，传输选择 `xhttp`、模式 `auto`、Flow 留空，Path 使用生成链接中的值。此功能仍依赖客户端能直连 VPS IP，不保证换传输后避免封锁。

上传文件：`speed-slayer-lite/install.sh`、`speed-slayer-lite/test.sh`、新增 `speed-slayer-lite/test-xhttp.sh`、两份 README 与 CHANGELOG；原有共享 Brutal 文件继续保留。上传前检查 `bash speed-slayer-lite/test.sh`。根目录 `install.sh` 仍是主版的 TCP 调优 / VMess+Argo 入口；安装 XHTTP 使用上面的 **Lite 路径**。

---

## TCP Brutal v2：可选直连 TCP 加速

此功能由主版和 Lite 共用，**不会随 `--all`、`--tcp` 或 Lite 普通安装自动启用**。保留系统原来的 BBR/FQ 配置，不更改 Xray 协议配置、节点凭据或 cloudflared 传输方式。TCP Brutal 固定为 `v2.0.0`，下载 DKMS 源码包时验证固定 SHA-256。

### 哪些节点适用

| 场景 | 是否适用 |
| --- | --- |
| Lite：VLESS + XHTTP + REALITY | 可为 VPS 发往客户端的 TCP 流量启用 |
| Lite：Shadowsocks 2022 | TCP 部分适用，UDP 部分不受影响 |
| 主版 / Lite：VMess + Argo | 默认优先使用 QUIC，本功能不自动加速这段 UDP 隧道 |

前提是 Debian/Ubuntu、systemd、**当前运行的 Linux 内核 >= 5.10**，并能安装匹配该内核的 headers 和加载 DKMS 模块。不强制安装 XanMod。管理器拒绝在容器内安装宿主机内核模块；受限 LXC/Docker 需要宿主机配合。已存在其他版本 Brutal 时，先由管理员处理版本切换，不会强制卸载活跃模块。

### 安装与首次使用

以下命令在 **Linux VPS 的 Bash 中以 root 执行**；普通用户先运行 `sudo -i`。

已经安装新版主程序：

```bash
speed --brutal install
```

已经安装新版 Lite：

```bash
speed-slayer-lite brutal install
```

也可以直接从 GitHub 的主入口安装 Brutal 管理器，无需重新部署现有节点：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Benjpsusu/speed-slayer/main/install.sh) --brutal install
```

安装后会提供独立命令 `speed-brutal`。**只安装模块不会让连接自动使用 Brutal，需要继续添加客户端规则。**

```bash
# 示例 IP 必须替换为“客户端访问 VPS 时，VPS 看到的客户端公网 IP”
# 100 代表发往这个客户端的所有 TCP 连接合计目标速率为 100 Mbps
speed-brutal add 203.0.113.5 100

# IPv6 示例，同样替换成真实客户端 IPv6
speed-brutal add 2001:db8::5 100

# 查看保存的规则、内核规则、连接数，以及路由是否生效
speed-brutal status

# 同一 IP 再次 add 即修改速率
speed-brutal add 203.0.113.5 80
```

也可使用 `speed --brutal add IP Mbps` 或 `speed-slayer-lite brutal add IP Mbps`，两者操作同一份规则。主版菜单入口是 `2. 一键TCP调优 → 4. TCP Brutal 管理`。

填写参数时注意：

- 下载方向在 VPS 配置**客户端 IP**，不是 VPS 自己的 IP、REALITY 伪装站域名或 Argo 域名。本版只接受单个 IPv4/IPv6 地址（或 `/32`、`/128`），不接受整个网段或默认路由。
- 按 VPS 到客户端的实际可用带宽填写 Mbps，支持整数 `1–100000`。不自动套用 `SPEED_BANDWIDTH_MBPS` 或 VPS Speedtest 上传结果。设得过高可能增加丢包、排队和带宽消耗，不保证一定优于 BBR。
- 规则覆盖 VPS 发往该 IP 的**所有 TCP 连接**，包括其他应用。同一公网 IP 后的多个用户会共享速率；移动网络、家庭宽带或 IPv6 隐私地址变化后，需要删除旧 IP 并添加新 IP。
- 首次添加规则后，需要在客户端断开并重新建立连接。修改已有规则的速率会作用于该组已有连接；删除规则后，已有连接仍保持原来的 Brutal 参数直到关闭。
- 添加前检查现有目标路由和策略路由；遇到冲突会拒绝覆盖。复杂路由请自行使用上游工具管理，不能与本管理器同时修改同一目标规则。

### 停用、删除与卸载

```bash
speed-brutal del 203.0.113.5  # 删除一条自有规则和持久配置
speed-brutal disable          # 清除全部自有规则并关闭开机恢复，保留备份
speed-brutal uninstall        # 停用并移除共享管理器；保留 DKMS 模块、brutalctl 和备份
```

`disable` 后需要重新 `add` 才会启用。清理只针对本管理器记录的目标，不执行 `brutalctl flush`，避免删除其他工具的规则。若清理失败，会返回失败并保留相应记录，修复环境后重新执行 `del` 或 `disable`。

Brutal 管理器由主版和 Lite 共享，**卸载主版或 Lite 不会连带移除它**。如需一起停用，先执行 `speed-brutal disable`。共享内核模块不会被自动卸载，以免影响其他支持 Brutal 的应用。

### 文件、开机恢复与排查

| 路径 | 用途 |
| --- | --- |
| `/etc/speed-slayer-brutal/rules.tsv` | 本管理器拥有的 IP / Mbps 规则，权限 `0600`，作为数据读取，不执行内容 |
| `/etc/speed-slayer-brutal/rules.tsv.bak` | 最近一次修改前的规则备份 |
| `/etc/speed-slayer-brutal/disabled-rules.tsv` | 最近一次停用操作前的规则备份 |
| `/usr/local/lib/speed-slayer/tcp-brutal.sh` | 主版和 Lite 共用的管理脚本 |
| `/etc/systemd/system/speed-slayer-brutal.service` | 网络就绪后恢复持久规则；添加第一条规则时启用 |

```bash
speed-brutal status
journalctl -u speed-slayer-brutal --no-pager -n 100
dkms status
```

内核升级后由 DKMS 构建模块，但仍取决于新内核的 headers、模块兼容性和加载权限；重启后检查 `status`。若开机恢复失败，修复后执行 `speed-brutal restore` 并重新建立客户端连接。`status` 中有规则但连接数为 0，不代表下载已加速，应在真实连接中验证。

实现依据：[TCP Brutal v2.0.0](https://github.com/HyNetworks/tcp-brutal/releases/tag/v2.0.0)、[上游说明](https://github.com/HyNetworks/tcp-brutal/blob/v2.0.0/README.zh.md)、[Cloudflare Tunnel 协议参数](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/#protocol)。

### 上传 GitHub 时需要保留的文件

按仓库现有目录结构上传，建议在同一个 Git 提交中发布，不能只上传主入口：

- `install.sh` 和 `scripts/vps-argo-vmess-oneclick.sh`：主版安装入口与 `--brutal` 命令。
- **`scripts/tcp-brutal.sh`**：两个入口需要下载的共享模块，缺少此文件会安装失败。
- `speed-slayer-lite/install.sh`：Lite 的 `brutal` 命令。
- `README.md`、`speed-slayer-lite/README.md`、`CHANGELOG.md`、`AGENTS.md`：用法与修改记录。
- `scripts/tests/tcp-brutal-test.sh`、`speed-slayer-lite/test.sh`、`.gitattributes`：检查脚本与 LF 换行约定。

文档中的远程命令以 **`Benjpsusu/speed-slayer` 仓库的 `main` 分支**为准，必须在这些文件上传之后使用。上传前可在 Linux 的本地仓库测试入口：

```bash
bash scripts/tcp-brutal.sh help
bash scripts/tests/tcp-brutal-test.sh
bash speed-slayer-lite/test.sh

# 下面这条会在当前 Linux VPS 真正安装模块；仅在准备好实机验证时执行
bash scripts/vps-argo-vmess-oneclick.sh --brutal install
```

两个入口固定校验共享脚本的 SHA-256。后续修改 `scripts/tcp-brutal.sh` 时，要先保持 UTF-8/LF，再同步更新两个入口中 `run_brutal` 的摘要；否则远程下载会因校验不符而停止。

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

当前脚本版本：`v2.0.9`

### v2.0.9

- 新增可选 TCP Brutal v2 共享管理器，主版与 Lite 均可调用。
- 默认保留 BBR/FQ；按客户端单 IP 管理规则、开机恢复、状态验证和清理。
- 新增用法、GitHub 上传说明及修改溯源约定。

## 修改记录（溯源）

后续每次修改都应追加记录，包含日期、目的、文件和验证情况；具体约定见 [AGENTS.md](AGENTS.md)。历史记录不得覆盖，尚未运行的检查不得标记为通过。

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
