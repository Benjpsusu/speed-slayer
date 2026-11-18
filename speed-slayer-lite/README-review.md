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

### 12. 新协议：VLESS + XHTTP + Cloudflare 命名隧道（勾选 5 / 菜单 13、14）

适用场景：服务器 IP 被封（TCP 全断），但服务器自己访问外网正常。链路是 `客户端 → Cloudflare 节点 → 命名隧道 → 本机 127.0.0.1`。Cloudflare 回源这一段在境外，所以 IP 被封不影响；本机也**不需要开放任何入站端口**。

- **必须用自有域名的命名隧道**。实测免域名的快速隧道（trycloudflare）会把流式响应的正文攒到最后才发出（官方文档也写明不支持 SSE），XHTTP 的下行因此在所有模式下都不通；VMess + WS 不受影响。命名隧道实测首个正文字节 0.06 秒就到达。
- **服务端**：新增入站 `vless-xhttp-cdn`，只监听 `127.0.0.1:CDN_PORT`（默认 30004），不开 TLS，模式 `auto`，保留默认的 SSE 响应头。UUID 和路径单独生成，与 REALITY 节点互不影响。
- **连接器**：新服务 `cloudflared-cdn-lite` 以 `cloudflared` 用户运行 `tunnel run`。token 只保存在 `cloudflared-cdn.env`（root 0600），不写入 state，也不会打印出来。
- **输入**：交互时要填主机名和 token（输入时不显示，可以直接粘贴整条 `cloudflared service install eyJ…` 命令），端口和客户端连接地址可选。连接地址默认是主机名，也可以填 Cloudflare 优选域名或 IP。token 会解码校验，必须包含隧道 ID。
- **上线自检**：启动后从连接器日志读取 Cloudflare 下发的远程路由，确认该主机名指向 `http://127.0.0.1:端口`（或 `localhost`），不一致时直接说明后台应该怎么改。然后用一个临时 Xray 客户端经 Cloudflare 走完整代理链路（`packet-up` 访问 generate_204）。任一步失败都会回滚。
- **客户端**：`show` 输出 `mode=packet-up` 的 vless 链接和 mihomo 片段。经 Cloudflare 实测：`packet-up` 和 `auto` 可用；`stream-up` 需要在域名设置里打开 gRPC；`stream-one` 不可用。
- **追加 / 移除**：`add-xhttp-cdn`（菜单 13）在已有节点上追加，只是加一个入站后重启 Xray，原有凭据不变。`remove-xhttp-cdn [--yes]`（菜单 14）删除入站、连接器和 token，`xray.json` 恢复成和追加前一字不差。两者都有维护锁、备份，失败会回滚。只装了 AnyTLS 时暂不支持追加，移除后只剩 AnyTLS 的情况也暂不支持（请卸载重装）。
- **更新 / 卸载 / 状态**：`update` 会一并更新 cloudflared，重启连接器并重新自检，失败回滚。卸载会清理连接器、单元和 token；`status` 会显示连接器状态。
- **同一个 token 不要同时在两台机器上运行**：Cloudflare 会把请求分给两台机器，XHTTP 的上下行会落到不同机器上导致断开。把隧道换到另一台机器之前，先在原机器执行菜单 14 移除。
- 顺带修复：`remove-anytls` 原来用 `${PROTOCOLS%,anytls}` 删除协议，要求 anytls 必须排在最后；新协议排在它后面时会删除失败。现改为与顺序无关的写法。

## 与原版的行为差异（使用前请看）

- **`SCRIPT_URL` 指向 `install-review.sh`**。用 review 版安装后，`update` 以及通过 `bash <(curl …)` 运行时的自我安装，都会从仓库的 `speed-slayer-lite/install-review.sh` 下载，因此需要先把该文件上传到同一路径。正式采纳（改名为 `install.sh`）时，请把第 13 行的 `SCRIPT_URL` 改回 `install.sh`。
- 菜单新增 `10`；80 被占用时 ACME 不可选。
- 已有安装运行 review 版的更新后，旧的 `backup-update-*` 只保留最近 3 份；需要更早的备份请先手动拷出。
- 原版在 OpenSSL 3 上生成的自签证书仍然有效，无需重新签发；原版在 1.1.1 上本来就会失败并回滚，不会留下坏证书。
- （2026-11-18）`update` 会把 Xray 换成 26.11.9；已有 AnyTLS 的单元会被改写一次，加入 `GODEBUG=multipathtcp=0`。
- （2026-11-18）菜单新增 `11`、`12`；`show` 的输出多了 mihomo 片段，原有链接不变。
- （2026-11-18）Xray 每次刚启动或重启时，REALITY 会先探测目标站握手后的记录长度。探测完成前进来的连接会等待约 5 秒，之后恢复正常。这是 REALITY 本身的机制，与本次改动无关；测试中观察到，记录在此，以免被误判为故障。
- （2026-11-18）协议勾选新增 `5`（VLESS + XHTTP + Cloudflare 隧道）；`a` 只全选 1–4，因为 5 需要自有域名和 token。菜单新增 `13`、`14`。`PROTOCOLS` 新增取值 `xhttpcdn`。

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

# VLESS + XHTTP + Cloudflare 命名隧道（IP 被封也能用；需要托管在 Cloudflare 的自有域名）
# 1. Cloudflare 后台 Networking → Tunnels → Create a tunnel，复制安装命令里 eyJ 开头的 token
# 2. 该隧道 → Routes → Add route → Published application：主机名 xhttp.example.com，Service URL http://127.0.0.1:30004
# 3. 新装：一键菜单里选 1 并勾选 5；或者非交互（以 root 运行，新机器上还没有 speed-slayer-lite 命令）：
PROTOCOLS=xhttpcdn CDN_DOMAIN=xhttp.example.com CDN_TOKEN='eyJ...' bash <(curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Benjpsusu/speed-slayer/refs/heads/main/speed-slayer-lite/install-review.sh) install
#    已有节点上追加 / 移除：
sudo CDN_DOMAIN=xhttp.example.com CDN_TOKEN='eyJ...' speed-slayer-lite add-xhttp-cdn
sudo speed-slayer-lite remove-xhttp-cdn --yes
# 可选：CDN_PORT（本机端口，默认 30004，必须与 Service URL 一致）、CDN_ADDRESS（客户端连接地址，可填优选域名或 IP）

# 新装时直接指定 SNI
sudo PROTOCOLS=vless REALITY_SERVER_NAME=speedtest.wobcom.de speed-slayer-lite install
```

**找离 VPS 近、又不是大厂的目标站**：在**本地电脑**上（不要在 VPS 上，官方说明扫描可能导致 VPS 被标记）用 XTLS 官方的 [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 扫描 VPS 所在网段，再把候选站点交给 `check-reality-target` 在 VPS 上复核。

扫描前先**关闭本机代理软件的 TUN / 全局模式**，或者把 VPS 网段设为直连。否则扫描流量可能经由代理节点（甚至就是这台 VPS）发出，等于还是在 VPS 上扫描。`-addr` 要写成 CIDR；只写一个 IP 会无限向外扩展扫描。

Windows（PowerShell 5.1 或 7 均可，逐段粘贴执行）：

```powershell
# 1. 扫描（扫描器在“下载”文件夹，结果写到桌面）
Set-Location "$env:USERPROFILE\Desktop"
& "$env:USERPROFILE\Downloads\RealiTLScanner-windows-64.exe" -addr '你的VPS_IP/24' -port 443 -thread 20 -timeout 5 -out near.csv

# 2. 取出证书域名：去掉通配符、去重，生成一行 VPS 命令并复制到剪贴板
$list = @(Import-Csv -LiteralPath .\near.csv -Encoding UTF8 |
    ForEach-Object { "$($_.CERT_DOMAIN)".Trim().ToLower() } |
    Where-Object { $_ -and $_ -notmatch '\*' } | Sort-Object -Unique)
"$($list.Count) candidates"
$cmd = 'speed-slayer-lite check-reality-target ' + ($list -join ' ')
$cmd; $cmd | Set-Clipboard
```

然后在 VPS 的 SSH 窗口里粘贴运行这一行。不要用 PowerShell 的 `>` 生成文件再传到 VPS：Windows PowerShell 5.1 的 `>` 会写成 UTF-16，`Set-Content` 会写 CRLF，bash 读到后会把域名当作无效。确实需要文件时，用 `[IO.File]::WriteAllText((Join-Path (Get-Location) 'candidates.txt'), ($list -join "`n") + "`n")` 写出不带 BOM 的 UTF-8 + LF 文件。

Linux / macOS / Git Bash：

```bash
./RealiTLScanner -addr 你的VPS_IP/24 -port 443 -thread 20 -timeout 5 -out near.csv
cut -d, -f9 near.csv | tail -n +2 | grep -v '\*' | sort -u > candidates.txt   # 第 9 列是 CERT_DOMAIN（新版 11 列格式）
speed-slayer-lite check-reality-target $(cat candidates.txt)                  # 在 VPS 上运行
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

### 2026-11-18 第 12 项（XHTTP + Cloudflare 隧道）的验证

**本地**（Windows Git Bash，通过 pwsh 调用）：
- `bash -n` 通过。`bash test-review.sh` 退出码 0，共 87 项通过：原有 XHTTP 13、管理 23、AnyTLS 37，review 回归 14。新增第 12–14 组用的都是合成 token，不含真实凭据。
- **红绿验证**：第 12–14 组逐组对 GitHub 上的改动前版本运行，3/3 失败（`cdn_token_tunnel_id: command not found`、`AnyTLS-only add must be refused`、`matching route rejected`）；对新版本运行 3/3 通过。
- 测试过程中修掉了 3 个实现问题：追加成功后没有删除下载暂存目录 `candidate/`；什么都没改成的失败会留下无用备份；state 原来经环境变量写入，在 Git Bash 下路径形状的值会被改写，现改为从 stdin 传入。

**测试机实测**（Debian 13，用户自有域名下的一条命名隧道，路由为 `主机名 → http://127.0.0.1:18090`；仓库公开，所以不写出具体域名；测试前先完整备份 Lite）：

| 步骤 | 结果 |
| --- | --- |
| 方案验证：快速隧道 + XHTTP（Xray / mihomo，所有模式） | 全部失败；流式正文被攒到最后才发出 |
| 方案验证：命名隧道 + XHTTP | `packet-up` / `auto` / 优选 IP 可用，下行约 16–17 MB/s，上行 7–14 MB/s；`stream-up`（未开 gRPC）、`stream-one` 不可用 |
| A. 在已有 VLESS 节点上追加，故意填错端口 18091 | 读出真实路由，报"转发到 http://127.0.0.1:18090，应为 …18091"；回滚后 `xray.json` 不变，单元和 token 都已删除 |
| B. 用正确端口追加 | 10 秒完成并通过自检；原入站不变；token 文件为 root 600 |
| 用 `show` 输出搭建客户端 | Xray（vless 链接）和 mihomo（YAML 片段）经 Cloudflare 均可用：204、下载 20 MB、上传 5 MB 都成功 |
| C. `remove-xhttp-cdn --yes` | `xray.json` 与追加前一字不差；CDN state、token、单元都已删除；REALITY 回环测试仍为 204 |
| D–F. 卸载后只用 `PROTOCOLS=xhttpcdn` 全新安装 | 14 秒完成：下载并校验 Xray 26.11.9 和 cloudflared 2026.10.3，自检通过；只监听 127.0.0.1；`show`、`status` 正常；卸载清理干净 |
| G. 从备份恢复原安装 | state 和 `xray.json` 的哈希与备份前一致；REALITY 为 204 |
| H. 用新脚本再次追加，供用户从国内测试 | 已在测试机上运行 |

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
- （2026-11-18，第 12 项）所有隧道测试的客户端都跑在测试机上，Cloudflare 节点离得很近，**没有从国内实际连接测试**，国内的速度和可用性取决于连到的 Cloudflare 节点和优选 IP。没有在 IP 真正被封的机器上安装过。只在 Debian 13 / amd64 上实测，arm64、Ubuntu 和交互式输入在真实终端里的表现没有测。与 VMess（Argo）同时安装、在只装 AnyTLS 的机器上新装组合，只有替身测试。`stream-up` 在打开 gRPC 后的表现没有测。

## 修改记录（溯源）

### 2026-11-18 — 新协议 VLESS + XHTTP + Cloudflare 命名隧道

- 目的：用户有一台机器 TCP 全断，想让 XHTTP 走 Cloudflare。实测快速隧道无法承载 XHTTP，命名隧道可以，所以把它做成 Lite 的协议选项。
- 改动：见上文第 12 项。新装勾选 5；追加菜单 13 / `add-xhttp-cdn`；移除菜单 14 / `remove-xhttp-cdn`；更新、卸载、状态都覆盖了连接器。顺带修复 `remove-anytls` 依赖协议顺序的问题。
- 涉及文件：`install-review.sh`、`test-review-cases.sh`（第 12–14 组）、`README-review.md`；根 `README.md` 和 Lite `README.md` 只追加修改记录。原 `install.sh` 和原有测试未改动。
- 验证：见"2026-11-18 第 12 项的验证"。
- 未验证：见"未验证"中标注第 12 项的条目。

### 2026-11-18 — 补充 Windows PowerShell 的目标站扫描写法

- 目的：用户在 Windows PowerShell 里运行文档给出的 `cut … | grep … | sort` 时报 `参数列表中缺少参量`，因为这些是 bash 命令，而扫描本来就建议在本地电脑上做。
- 改动：在"用法"中补充 PowerShell 写法。扫描器用完整路径运行；用 `Import-Csv` 按表头取 `CERT_DOMAIN`，兼容 11 列和旧版 5 列格式；去掉通配符、去重，生成一行 VPS 命令并复制到剪贴板。说明 `>`（UTF-16）和 `Set-Content`（CRLF）为什么不能用来生成给 bash 的文件。补充扫描前关闭本机代理 TUN 的提醒。原 bash 写法保留，并注明只适用于 11 列格式。
- 涉及文件：`README-review.md`；根 `README.md` 和 Lite `README.md` 只追加记录。没有修改脚本。
- 验证：用样本 CSV（11 列、旧 5 列、含引号的签发者字段、通配符和重复域名）在 Windows PowerShell 5.1.19041 与 PowerShell 7.6.9 中运行提取命令，结果正确。写出的文件为 LF、无 BOM；在 bash 中经 `reality_target_normalize` / `validate_domain` 校验有效。
- 未验证：没有实际运行 RealiTLScanner（本机没有用户的 `near.csv`）；`Set-Clipboard` 和整段粘贴只按语法确认，没有在用户的终端里实际执行。

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
