# Speed Slayer Lite — Review 修复版

本版本根据 2026-11-05 对 Lite（重点为 AnyTLS 两次提交 `e6ef321`、`241939d`）的 review 结果修复；2026-11-18 又追加了 REALITY 目标站管理、mihomo 片段和 MPTCP 安全更新（见“2026-11-18 追加”）。按要求**不覆盖原文件**，所有改动放在带 `-review` 后缀的新文件中：

| 文件 | 说明 |
| --- | --- |
| `install-review.sh` | 修复后的安装/管理脚本，基于 `install.sh`（`241939d`） |
| `test-review.sh` | 用**未改动**的原有 4 套测试校验 review 版，再运行新增回归测试 |
| `test-review-cases.sh` | review 回归测试：第 1–7 组（2026-11-05）、第 8–11 组（2026-11-18） |
| `README-review.md` | 本文：修复说明、用法差异、验证记录 |

原 `install.sh`、`test*.sh`、`test-anytls-loopback.py`、`README.md` 以及根目录文件均未修改。

## 修复内容

### 1. 自签证书在 OpenSSL 1.1.1 上生成重复扩展（高）

**问题**：原脚本用 `openssl req -x509 -addext basicConstraints=critical,CA:FALSE ...`，但没有指定 `-config`。

- OpenSSL 1.1.1 的 `apps/req.c` 使用 `X509V3_set_ctx(..., 0)`，`-addext` 会**追加**到配置的 `x509_extensions` 之后；3.0 才改为 `X509V3_CTX_REPLACE`。
- Debian 11（1.1.1w）和 Ubuntu 20.04（1.1.1f）的默认 `openssl.cnf` 中，`[req] x509_extensions = v3_ca`，且 `v3_ca` 含 `basicConstraints = critical,CA:true`。
- 生成的证书因此同时带有 `CA:TRUE` 和 `CA:FALSE` 两个 basicConstraints。Go 的 `x509.ParseCertificate` 会拒绝重复扩展，而 sing-box 1.14.4 通过 `tls.X509KeyPair` 加载证书，所以自签模式在这两个最低支持版本上会在 `sing-box check` 处失败并回滚。

**改动**：

- `generate_anytls_certificate`：在临时目录写入私有 `req.cnf`，用 `-config` 生成，不再使用 `-addext`，系统配置不会混入证书。扩展包括 IP SAN、`basicConstraints=critical,CA:FALSE`、`keyUsage=critical,digitalSignature`、`extendedKeyUsage=serverAuth`、SKI/AKI；首次签发和续期都用这一路径。该写法在 1.1.1 与 3.x 上一致。
- `check_anytls_certificate`：用一个小型 DER 解析检查证书链中的每张证书，发现重复扩展即报错（“证书包含重复扩展……sing-box 无法加载”）。已有证书（file）模式同样受益，错误在 sing-box 加载前给出。

### 2. 备份目录无限增长（中）

**问题**：每次更新都把旧二进制和整个 `candidate/`（压缩包和解压后的二进制，sing-box 单个约 81 MB）留在 `/etc/speed-slayer-lite/`，从不清理；追加 AnyTLS 和刷新证书也会累积备份，其中含私钥副本。

**改动**：

- `apply_update` 和 `do_add_anytls` 无论成功或失败都会删除 `candidate/`。恢复只用备份根目录中的旧二进制，从不需要它。
- 新增 `prune_backups`，每类备份保留**当前这份加上较新的另外 2 份**（`BACKUP_KEEP=3`），适用于 `backup-update-*`、`backup-anytls-*`、`backup-cert-*`、`backup-remove-anytls-*`。迁移备份 `backup-xhttp-*` 是一次性的，不受影响。当前操作产生的备份永远不会被删除。

### 3. 无法单独移除或重配 AnyTLS（中）

**问题**：更换证书方式（例如 80 后来被网站占用，从 ACME 改成自签）、域名、端口，或服务器 IP 变化后更新自签 IP，都只能整体卸载，从而丢失其他节点的凭据。

**改动**：新增 `remove-anytls` 命令和菜单 `10. 移除 AnyTLS（保留其他节点）`。

- 需要输入 `y` 确认（回车即取消），无人值守时可加 `--yes`；与其他维护操作共用维护锁。
- 执行顺序：停止 `anytls-lite`，然后写入新 state（`PROTOCOLS` 去掉 anytls，`ANYTLS_*` 清空），重新生成节点信息，最后才删除 unit、`anytls.json`、`bin/sing-box`、`tls/`、`acme/`。删除之前的任一步失败，都会恢复原 state 和节点信息并重新启动 AnyTLS。
- 不重启、不修改 Xray/Argo；保留共享 sing-box、外部源证书和系统账户。
- 只装了 AnyTLS 时拒绝执行，提示改用卸载（Lite 至少需要保留一个协议）。
- 移除后可用菜单 8 / `add-anytls` 以新方式重新追加。原 state 备份在 `backup-remove-anytls-*`，需要沿用旧密码时可传入 `ANYTLS_PASSWORD`。

### 4. 菜单中任一操作失败会退出整个菜单（低）

**问题**：例如已装 AnyTLS 时选 8、ACME 模式选 9、未装 VMess 时选 6，`die` 在 `set -e` 下会直接结束脚本。

**改动**：新增 `menu_run`，每个菜单操作都在子 shell 中运行，并在其中重新开启 `set -e`。失败时提示“操作未完成（退出码 N），已返回菜单。”并回到菜单。这里刻意不写成 `action || ...`，因为在那种上下文里 bash 会关闭整个函数体内的 `set -e`。

### 5. 同一菜单会话中“安装 → 卸载 → 再安装”会复用 AnyTLS 密码（低）

**问题**：`do_install` 在菜单进程里运行，生成的 `ANYTLS_PASSWORD`（以及 `XHTTP_PATH`）留在全局变量中，再次安装时 `${ANYTLS_PASSWORD:-…}` 会直接沿用，与“卸载会删除凭据”的说明不符。

**改动**：由第 4 项的子 shell 隔离一并解决，菜单中的安装不再把生成的凭据泄漏到后续操作。

### 6. 交互输入校验过晚（低）

**改动**（`configure_anytls`）：

- TCP 80 被占用时提前提示，证书方式默认改为 `3`（自签），并拒绝选择 `1`（ACME）。
- 自签 IP、端口、邮箱、证书和私钥路径都在输入时校验，无效就当场重新询问。端口另外检查是否被占用、是否与 VLESS 端口相同。输入中途遇到 EOF 会取消，不会死循环。
- 新增 `valid_email`、`valid_cert_source` 两个辅助函数，与非交互校验共用同一套规则。
- `do_install` 改为在下载内核前解析和校验自签 IP，地址无效时尽早失败，不浪费下载。

## 2026-11-18 追加：Xray 安全更新、MPTCP、REALITY 目标站与 mihomo

起因：AnyTLS 端口再次被封，群友推荐改用 VLESS + XHTTP + REALITY（SNI `speedtest.wobcom.de`），并要求 mihomo 加 `support-x25519mlkem768: true`、服务端设 `minClientVer 1.8.3`。核对源码后结论如下，改动 7–11 由此而来。

### 7. Xray 升级到 26.11.9（高，安全）

- 原固定的 26.10.21 早于 [v26.10.31 紧急安全更新](https://github.com/XTLS/Xray-core/releases/tag/v26.10.31)。Linux 内核刚曝出一个漏洞：服务监听 IPv4 MPTCP 时，可能被远程拿到 root；而 Go 1.24+ 默认让监听端口开启 MPTCP。v26.10.31 起 Xray 默认关闭 MPTCP（[PR #7291](https://github.com/XTLS/Xray-core/pull/7291)）。同一讨论里，MPTCP 内核维护者指出，**只关闭 MPTCP 不能完全防住，根本办法是升级内核**。
- 新的固定 SHA-256：amd64 `b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82`，arm64 `64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be`。这两个值由本地下载后计算，与官方 `.dgst` 文件、GitHub 资产摘要三方一致。
- 26.10.31 和 26.11.9 的更新说明里都没有影响 Lite 配置的改动。26.11.9 的 `xray x25519` 输出改成了 `Password (PublicKey): …`，原有的 `awk` 解析仍能正确取到公钥（已用真实程序确认）。

### 8. AnyTLS 关闭 MPTCP 监听（高，安全）

- sing-box 1.14.4 的 `go.mod` 是 `go 1.25.5`。它只在配置了 `tcp_multi_path` 时才显式开启 MPTCP，否则沿用 Go 默认值。[Go 1.24 起监听端口默认 `multipathtcp=2`](https://github.com/golang/go/blob/master/doc/godebug.md)，也就是默认开启，所以 AnyTLS 公网端口同样受影响。
- `anytls-lite.service` 加入 `Environment=GODEBUG=multipathtcp=0`（Go 文档说明：`0` 表示 dialer 和 listener 默认都不用 MPTCP）。
- 已有安装在执行 `update` 时，如果单元文件缺少这一行，会按 state 重写单元并执行 `daemon-reload`。更新失败时恢复旧单元；单元已经包含这一行的，不会重复改写。

### 9. 新命令 `set-reality-sni` / 菜单 11（中）

- 原脚本没有修改 SNI 的入口，只能卸载重装（丢失全部凭据）或手动改 3 处配置。
- 只修改 SNI 相关的 3 个字段：state 的 `REALITY_SERVER_NAME`；`xray.json` 中守门入站的地址、`serverNames`，以及守门路由规则。端口、UUID、密钥、shortId、XHTTP 路径都不变，也不动 AnyTLS。
- 修改前会先用 `check-reality-target` 的规则从本机检查新目标站。检查不通过时：交互模式询问是否继续，非交互模式拒绝执行（需要加 `--force` 才会继续）。
- 用维护锁防止并发，先备份，并用 `xray run -test` 校验新配置。重启失败时自动恢复原配置和节点信息，并重新启动 Xray。如果 `xray.json` 与 state 不一致（例如手动加了第二个 serverName），会拒绝覆盖。备份保留 3 份（`backup-sni-*`），什么都没改成的失败不会留下备份。
- 支持输入 `https://域名/路径` 的形式，会自动只取出小写域名。
- 重启 `xray-lite` 会连带重启 Quick Tunnel（`PartOf`），VMess 临时域名可能变化，执行时会给出提示。

### 10. 新命令 `check-reality-target` / 菜单 12（中）

- 从 VPS 本机逐个检查候选目标站，按 REALITY 对目标站的要求判定：TLS 1.3、h2、证书与域名匹配，以及首页没有跳转到其他域名、也没有返回 4xx/5xx。另外列出 VPS 解析到的 IP、建连耗时和协商的密钥交换组。
- OpenSSL 3.5+ 会像浏览器一样优先提供 X25519MLKEM768；Debian 11/12 自带的旧版 OpenSSL 只测 X25519，GROUP 列如实显示。握手失败时 `s_client` 仍会打印 `Verify return code: 0`，这种情况不会当作证书有效。
- 不带参数时检查当前 SNI（需要 root）。只要有一个候选可用就返回 0，全部不可用返回 1。菜单 12 在安装前也能用，方便自定义 SNI 前先检查。

### 11. `show` 输出 mihomo 配置片段（中）

- 当前 REALITY 库（commit `8cdf7bf`，2026-09-08，26.10.21 和 26.11.9 都已包含）会把**不含 X25519MLKEM768 的 ClientHello 判定为认证失败**，连接转给目标站。而 mihomo 默认会删掉这个 key share（`component/tls/reality.go`），所以不加 `support-x25519mlkem768: true` 根本连不上。
- `show` 在 VLESS 链接后输出完整的 mihomo YAML 片段，所有字符串值都加了引号，避免纯数字 shortId 被解析成数字。IPv6 地址不带方括号。XHTTP 和旧的 TCP + Vision 节点各自输出对应写法。
- **服务端不设 `minClientVer`**：mihomo（Meta 与 Alpha 分支）和 sing-box 都把 REALITY 客户端版本写死为 `1.8.2`，设成 `1.8.3` 会把它们全部拒绝。下面的端到端测试已验证这一点。

## 与原版的行为差异（使用前请看）

- **`SCRIPT_URL` 指向 `install-review.sh`**。用 review 版安装后，`update` 以及通过 `bash <(curl …)` 运行时的自我安装，都会从仓库的 `speed-slayer-lite/install-review.sh` 下载，因此需要先把该文件上传到同一路径。正式采纳（改名为 `install.sh`）时，请把第 13 行的 `SCRIPT_URL` 改回 `install.sh`。
- 菜单新增 `10`；80 被占用时 ACME 不可选。
- 已有安装运行 review 版的更新后，旧的 `backup-update-*` 只保留最近 3 份；需要更早的备份请先手动拷出。
- 原版在 OpenSSL 3 上生成的自签证书仍然有效，无需重新签发；原版在 1.1.1 上本来就会失败并回滚，不会留下坏证书。
- （2026-11-18）`update` 会把 Xray 换成 26.11.9；已有 AnyTLS 的单元会被改写一次，加入 `GODEBUG=multipathtcp=0`。
- （2026-11-18）菜单新增 `11`、`12`；`show` 的输出多了 mihomo 片段，原有链接不变。
- （2026-11-18）Xray 每次刚启动或重启时，REALITY 会先探测目标站握手后的记录长度。探测完成前进来的连接会等待约 5 秒，之后恢复正常。这是 REALITY 本身的机制，与本次改动无关；测试中观察到，记录在此，以免被误判为故障。

## 用法

```bash
# 一键菜单（review 版，需先上传 install-review.sh）
bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install-review.sh)

# 单独移除 AnyTLS（保留其他节点）
sudo speed-slayer-lite remove-anytls          # 需输入 y 确认
sudo speed-slayer-lite remove-anytls --yes    # 无人值守

# 例：服务器 IP 变化后，改用新 IP 重新追加自签 AnyTLS
sudo speed-slayer-lite remove-anytls --yes
sudo ANYTLS_CERT_MODE=selfsigned ANYTLS_ADDRESS=203.0.113.20 ANYTLS_PORT=8443 \
  speed-slayer-lite add-anytls

# 检查候选 REALITY 目标站（在 VPS 上运行；不带参数则检查当前 SNI）
speed-slayer-lite check-reality-target speedtest.wobcom.de a.example.com b.example.com
sudo speed-slayer-lite check-reality-target

# 修改 REALITY SNI / 目标站（先检查，未通过时拒绝；确认要用加 --force）
sudo speed-slayer-lite set-reality-sni speedtest.wobcom.de
sudo speed-slayer-lite set-reality-sni some.example.com --force

# 新装时直接指定 SNI
sudo PROTOCOLS=vless REALITY_SERVER_NAME=speedtest.wobcom.de speed-slayer-lite install
```

**找离 VPS 近、又不是大厂的目标站**：在**本地**（不要在 VPS 上，官方说明扫描可能导致 VPS 被标记）用 XTLS 官方的 [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 扫描 VPS 所在网段，再把候选站点交给 `check-reality-target` 在 VPS 上复核：

```bash
./RealiTLScanner -addr 你的VPS_IP/24 -port 443 -thread 20 -timeout 5 -out near.csv   # 写 CIDR；只写 IP 会无限向外扩
cut -d, -f9 near.csv | tail -n +2 | grep -v '\*' | sort -u > candidates.txt         # 第 9 列是 CERT_DOMAIN
speed-slayer-lite check-reality-target $(cat candidates.txt)                        # 在 VPS 上运行
```

扫描器按 IP 扫描时不发送 SNI，也不校验证书，所以结果必须复核。挑选标准：结论列显示"可用"；IP 列落在 VPS 所在网段（如果解析到 CDN，说明并不近）；CONN_MS 越小越好。挑出 CDN 和大厂之外的普通网站。

**mihomo**：直接使用 `show` 输出的 YAML 片段，`support-x25519mlkem768: true` 不能删。服务端不要加 `minClientVer`。

其余命令与环境变量同原 `README.md`。

## 验证

```bash
bash test-review.sh
```

2026-11-05 在 Windows Git Bash（OpenSSL 3.5.4、Python 3.12）下运行，退出码 0，共 80 项通过：

- `bash -n install-review.sh` 语法检查通过。
- 原有测试（未改动，运行对象为 review 版）：自检通过；XHTTP 13 项、管理 23 项、AnyTLS 37 项全部通过。另有 2 项真实 sing-box 连接测试因未设置 `SPEED_TEST_SINGBOX` 跳过。
- 新增回归测试：7 项全部通过。

**红绿验证**：把 7 组新增用例逐组拆开，分别对原 `install.sh` 和 `install-review.sh` 运行。结果原版 7/7 失败，review 版 7/7 通过，证明这些用例能捕获原问题。原版的失败原因：

| 用例 | 原 `install.sh` 的失败原因 |
| --- | --- |
| 1 自签证书不受系统 OpenSSL 配置影响 | `system OpenSSL req defaults leaked into the certificate`（模拟的 `v3_ca` 扩展混入证书） |
| 2 重复扩展证书被拒绝 | `duplicate extension not reported` |
| 3 备份清理 | `update backups not pruned to 3` |
| 4 remove-anytls | `do_remove_anytls: command not found` |
| 5 菜单失败后返回、重装生成新密码 | 选 8 时 `ERROR: 已安装 AnyTLS` 直接结束菜单 |
| 6 交互即时校验 | `certificate path retry`（无效路径被直接接受） |
| 7 自签 IP 在下载前解析 | `IP detection failure must stop before downloads` |

用例 1 用 `OPENSSL_CONF` 指向一份模拟的系统配置（`v3_ca` 含 `CA:true` 和一个标记扩展），检查生成的证书只有一个 `CA:FALSE` 的 basicConstraints，且不含标记扩展。在 OpenSSL 3 上也能据此证明系统配置不再参与签发。

### 2026-11-18 追加部分的验证

环境：Windows Git Bash，OpenSSL 3.5.4，curl 8.23.0（Schannel），Python 3.12；通过 `pwsh` 调用 bash。

- `bash -n` 检查 `install-review.sh`、`test-review-cases.sh`、`test-review.sh`，全部通过。
- `bash test-review.sh` 退出码 0，共 84 项通过：原有 XHTTP 13 项、管理 23 项、AnyTLS 37 项，review 回归 11 项。另有 2 项真实 sing-box 连接测试因未设置 `SPEED_TEST_SINGBOX` 跳过。
- 用 `SPEED_TEST_XRAY` 指向真实 Windows Xray 26.11.9 运行原有的 `test-xhttp.sh`，13 项通过（配置由真实内核校验）。
- **红绿验证**：把第 8–11 组逐组拆开，分别对改动前的 `install-review.sh` 副本和改动后的版本运行。旧版 4/4 失败，新版 4/4 通过；第 1–7 组在两版上都通过。旧版的失败原因：

| 用例 | 改动前的失败原因 |
| --- | --- |
| 8 Xray 版本与 MPTCP | `Xray 26.10.21 predates the MPTCP fix` |
| 9 set-reality-sni | `do_set_reality_sni: command not found` |
| 10 check-reality-target | `do_check_reality_target` 不存在 |
| 11 mihomo 片段 | `client-info.txt` 中没有 mihomo 片段（`IndexError`） |

- **真实 Xray 26.11.9**：对安装生成的 `xray.json` 和 `set-reality-sni` 改写后的配置运行 `xray run -test`，都输出 `Configuration OK.`。
- **真实站点**：用本机 OpenSSL / curl 运行 `check-reality-target`。speedtest.wobcom.de 和 learn.microsoft.com（302 到同域名）判为可用；google.com（跳转到 www）、wrong.host.badssl.com（TLS 1.2、证书 62）、expired.badssl.com、不存在的域名判为不合格；全部不可用时退出码为 1。本机走 fake-ip 代理，所以 IP 和 CONN_MS 两列在本地没有意义。
- **端到端**（只走回环）：服务端用 Lite 生成的配置，跑真实 Xray 26.11.9，只把 VLESS 监听改为 127.0.0.1；客户端用 `show` 生成的 YAML 片段，跑真实 mihomo v1.19.34（官方 Windows 包，SHA-256 已核对）；通过 mihomo 请求 `http://1.1.1.1/cdn-cgi/trace`：

| 场景 | 结果 |
| --- | --- |
| A. Lite 默认 + `support-x25519mlkem768: true` | 成功（HTTP 301）；mihomo 日志 `REALITY Authentication: true`，用到 X25519MLKEM768 |
| B. 去掉 `support-x25519mlkem768` | 失败：`REALITY authentication failed`，连接被转给目标站 |
| C. 服务端 `minClientVer 1.8.3` | 失败：`REALITY authentication failed` |
| D. 服务端 `minClientVer 1.8.2`（边界对照） | 成功 |

  A 和 D 在 Xray 刚启动时约需 6 秒；预热 8 秒后再测 A 只需 1.06 秒，原因见"行为差异"。Xray 26.11.9 的 freedom 出站会拦截私有地址（`target blocked by a finalrule`），所以测试目标选了公网 IP，没有用本地 HTTP 服务或 fake-ip 域名。

## 未验证

- 没有在真实 OpenSSL 1.1.1（Debian 11 / Ubuntu 20.04）上实测。第 1 项的结论依据 OpenSSL、Debian 和 Go 的源码，以及上面的模拟测试；建议在 Debian 11 容器或 VPS 上跑一次自签安装。
- 没有设置 `SPEED_TEST_SINGBOX`，真实 sing-box 回环连接测试跳过（原测试中 2 项）。
- 所有测试都在 Windows Git Bash（OpenSSL 3.5.4、Python 3.12）下运行，systemd、包管理、下载、用户/属主均为替身。Linux 上的实际权限（例如 `remove-anytls` 后 `chmod 0750`）、端口绑定和 ACME 签发都未实测。
- `shellcheck` 本机不可用，未运行。
- （2026-11-18）没有在 Linux VPS 上运行 `set-reality-sni`、`check-reality-target` 或 `update`。Debian 11/12 自带 OpenSSL 1.1.1/3.0 的 `Server Temp Key` 输出分支只用样本数据测过；Linux 下 curl 的输出格式也没有实测。
- （2026-11-18）`GODEBUG=multipathtcp=0` 对 sing-box 的实际效果没有在 Linux 上验证（Windows 不支持 MPTCP）。可以在 VPS 上确认：`tr '\0' '\n' </proc/$(pidof sing-box)/environ | grep GODEBUG`，以及 `ss -Mltn` 中没有 AnyTLS 端口。
- （2026-11-18）**这次改动不修复内核漏洞**，只是减少暴露面；请按发行版的安全公告升级内核。
- （2026-11-18）arm64 版 Xray 只核对了摘要，没有运行。端到端只测了 mihomo v1.19.34（Windows）；sing-box 和 v2rayN 客户端这次没有做端到端测试。
- （2026-11-18）RealiTLScanner 的用法和 CSV 列号来自其 README 和 `main.go` 源码，本次没有实际扫描。

## 修改记录（溯源）

### 2026-11-18 — Xray 26.11.9、AnyTLS 关闭 MPTCP、REALITY SNI 管理与 mihomo 片段

- 目的：AnyTLS 端口再次被封，改用 VLESS + XHTTP + REALITY 时需要能换 SNI、检查目标站、给出可用的 mihomo 配置；排查中发现固定的 Xray 26.10.21 早于 MPTCP 安全更新，sing-box 也同样开着 MPTCP 监听。
- 改动：见上文第 7–11 项。
- 涉及文件：`install-review.sh`（版本与 SHA-256、AnyTLS 单元、`update` 迁移与回滚、`set-reality-sni`、`check-reality-target`、菜单 11/12、mihomo 片段、安装 SNI 提示）、`test-review-cases.sh`（xray 替身支持 `run -test` 失败，新增第 8–11 组）、`README-review.md`。原 `install.sh` 和原有测试未改动。
- 验证：见"2026-11-18 追加部分的验证"。
- 未验证：见"未验证"中标注 2026-11-18 的条目。

### 2026-11-05 — Review 修复版（新增文件，不覆盖原文件）

- 目的：修复 review 发现的问题，包括自签证书在 OpenSSL 1.1.1 上的重复扩展（高）、备份无限增长（中）、无法单独移除或重配 AnyTLS（中），以及菜单失败退出、同会话重装复用密码、交互校验过晚（低）。
- 涉及文件：新增 `install-review.sh`、`test-review.sh`、`test-review-cases.sh`、`README-review.md`。
- 验证：见上文“验证”一节。
- 未验证：见上文“未验证”一节。
- 说明：按用户要求不覆盖原文件，因此本次没有写入根 `README.md` 和 `speed-slayer-lite/README.md` 的修改记录（AGENTS.md 约定）。正式采纳并替换 `install.sh` 时，需要把本条补记到这两处，同时改回 `SCRIPT_URL`。
