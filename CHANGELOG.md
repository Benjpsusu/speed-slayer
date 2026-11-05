# CHANGELOG

## v2.3.0 - 2026-11-05

- AnyTLS 证书方式新增 `selfsigned`：IP 直连，无需域名/SNI/邮箱，不使用 TCP 80；支持自动检测或指定 IPv4/IPv6。
- 生成包含 IP SAN 的自签证书；输出公有 PEM 和公钥指纹，新增 `export-anytls-client` 导出 sing-box 公钥固定配置。分享链接保留 `insecure=0`，客户端需单独导入证书信任。
- 菜单 9 支持沿用原私钥续期自签证书；更新保留证书、私钥、密码，失败恢复；现有域名证书模式不自动转换。
- 扩展交互、地址校验、证书持久性、续期恢复及真实无 SNI / 公钥固定连接测试；验证结果与未验证项见 README 同日记录。

## v2.2.0 - 2026-11-05

- Lite 新增 AnyTLS 协议勾选和独立 sing-box 服务；自动选择 Linux amd64/arm64 包并核对 SHA-256，固定 sing-box 1.14.4，保留原 Xray/cloudflared 版本。
- 支持 ACME HTTP-01 自动申请/续期、已有可信证书及验证失败恢复；输出开启证书校验的 `anytls://` 链接。
- 新增菜单 8 / `add-anytls`，保留已有节点追加 AnyTLS；菜单 9 / `refresh-anytls-cert` 刷新外部续期的证书副本。
- 更新、备份、状态与卸载按所选协议处理；AnyTLS 使用自有二进制，不覆盖已有 sing-box；卸载保留共享程序和外部源证书。
- 新增隔离管理与真实 AnyTLS 本机连接测试；验证结果、运行边界及未验证项见两份 README 当日记录。

## v2.1.0 - 2026-10-26

- 删除 TCP Brutal 模块、测试、主版和 Lite 入口；历史修改记录保留。
- Lite 默认进入管理菜单，支持勾选创建 VMess / SS2022 / VLESS；未选协议不部署，未选 VMess 不下载或启动 Argo。
- VLESS 支持默认 `learn.microsoft.com` / 自定义 SNI，新安装默认 TCP 443 并允许自定义端口；同步生成目标、守门规则和链接。
- 新增保留配置与凭据的管理脚本/内核更新，固定 Xray 26.10.21、cloudflared 2026.10.3 及 amd64/arm64 摘要，备份校验后切换，失败时恢复。
- 卸载默认取消，确认后删除 Lite 节点与备份，保留共享二进制和账户；主版新增 `--lite` 与菜单 8。
- 新增协议组合、交互、更新恢复、旧状态兼容、卸载范围测试，完整验证与未验证项见根 README 当日记录。

## Lite XHTTP - 2026-10-26

- Lite 新安装的 VLESS 改为 XHTTP + REALITY，使用随机路径与 `mode=auto`，移除 Vision flow，并生成对应分享链接。
- 新增保留原端口和凭据的 `migrate-xhttp`，包含备份、Xray 配置校验、服务重启和失败恢复；旧安装未迁移时仍输出原 TCP 链接。
- 新安装可指定 `REALITY_PORT=443`，按需为低权限 Xray 添加端口绑定能力；默认仍为 `30002/TCP`。
- 新增隔离测试及 README 安装、迁移、客户端配置和 GitHub 上传说明。Bash 语法、原有自检、13 项 XHTTP 检查及真实 Xray `26.3.27` 服务端/客户端配置校验通过；Linux 实机连接尚未验证，完整结果记录在根 README。

## v2.0.9 - 2026-09-05

### Added

- 主版 `speed --brutal` / TCP 子菜单及 Lite `brutal` 子命令，共用独立的 `speed-brutal` 管理器。
- 固定 TCP Brutal v2.0.0 源码包与 SHA-256，检测内核、headers、systemd 和容器限制。
- 按单个 IPv4/IPv6 客户端 IP 配置总发送速率，支持开机恢复、状态检查、删除、停用与独立卸载。
- 路由冲突检查、失败恢复及自有规则清理；默认流程不启用 Brutal，不修改全局 BBR/FQ 或 Argo。
- README 用法、GitHub 上传清单、修改溯源记录及 `AGENTS.md` 后续记录约定。

### Validation

- Bash 语法、25 项隔离检查及 Lite 原有自检通过；核对上游发布包 SHA-256 和源码包结构。
- 尚未进行 Linux VPS 的 DKMS 编译/加载、真实 systemd 重启恢复或吞吐测试。

## v1.0.0 - 2026-04-28

### Added
- 正式稳定版发布。
- README 正式化与项目说明美化。
- 鸣谢 @Eric86777 的 TCP 调优思路、NodeSeek 帖子与 vps-tcp-tune 仓库。

### Changed
- 版本号从 `v0.9.0-beta` 升级为 `v1.0.0`。
- README 聚焦快速开始、控制台、TCP 智能调优、Argo VMess WebSocket、诊断修复与更新说明。

### Notes
- v1.0.0 已通过实机测试，后续进入 bugfix 与兼容性增强阶段。

## v0.9.0-beta - 2026-04-28

### Added
- Speed Slayer 控制台与 `speed` 快捷命令。
- 一键完整流程：TCP 智能调优 + Argo VMess WebSocket 节点部署。
- XanMod / BBR v3 内核安装与重启后自动续跑。
- TCP 智能调优：内存/SWAP 检测、Speedtest 带宽探测、动态 buffer、FQ 队列、limits、DNS、IPv6 策略。
- 原生 Argo VMess+WS：cloudflared + Xray + Nginx + systemd。
- VMess URL、Base64、Clash、Shadowrocket、Auto 订阅生成。
- `speed --doctor` 全链路诊断。
- `speed --logs` 日志菜单。
- `speed --repair` 重复安装修复。
- `speed --speedtest` Ookla Speedtest 测速。
- `speed --netcheck` 网络连通性检测。
- 安装完成结果页与 CDN 优选提示。

### Changed
- 首页 UI 中文化与控制台二级菜单收拢。
- 自更新优先使用 GitHub API raw contents，减少 raw CDN 缓存影响。
- TCP 调优前台分阶段显示并同步写入日志。
- 重复安装前自动清理旧服务、旧进程与旧配置。

### Fixed
- 修复 `printf` 百分号导致脚本退出。
- 修复 VMess-only 校验误判 `vmess-ws` 为 `ss-ws` 残留。
- 修复 XanMod 包名硬拼导致的安装验证失败，改为 apt 候选探测与 fallback。
- 修复内核安装完成后未交互确认重启的问题。
- 修复更新提示把旧版本误判为新版本的问题。
- 修复终端 UI 颜色变量未定义问题。

### Notes
- 这是 Beta 版本，主流程已可用；建议继续进行多系统实机回归。
