# Speed Slayer Lite — Review 修复版

本版本根据 2026-11-05 对 Lite（重点为 AnyTLS 两次提交 `e6ef321`、`241939d`）的 review 结果修复。按要求**不覆盖原文件**，所有改动放在带 `-review` 后缀的新文件中：

| 文件 | 说明 |
| --- | --- |
| `install-review.sh` | 修复后的安装/管理脚本，基于 `install.sh`（`241939d`） |
| `test-review.sh` | 用**未改动**的原有 4 套测试校验 review 版，再运行新增回归测试 |
| `test-review-cases.sh` | 针对本次修复的 7 组回归测试 |
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

## 与原版的行为差异（使用前请看）

- **`SCRIPT_URL` 指向 `install-review.sh`**。用 review 版安装后，`update` 以及通过 `bash <(curl …)` 运行时的自我安装，都会从仓库的 `speed-slayer-lite/install-review.sh` 下载，因此需要先把该文件上传到同一路径。正式采纳（改名为 `install.sh`）时，请把第 13 行的 `SCRIPT_URL` 改回 `install.sh`。
- 菜单新增 `10`；80 被占用时 ACME 不可选。
- 已有安装运行 review 版的更新后，旧的 `backup-update-*` 只保留最近 3 份；需要更早的备份请先手动拷出。
- 原版在 OpenSSL 3 上生成的自签证书仍然有效，无需重新签发；原版在 1.1.1 上本来就会失败并回滚，不会留下坏证书。

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
```

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

## 未验证

- 没有在真实 OpenSSL 1.1.1（Debian 11 / Ubuntu 20.04）上实测。第 1 项的结论依据 OpenSSL、Debian 和 Go 的源码，以及上面的模拟测试；建议在 Debian 11 容器或 VPS 上跑一次自签安装。
- 没有设置 `SPEED_TEST_SINGBOX`，真实 sing-box 回环连接测试跳过（原测试中 2 项）。
- 所有测试都在 Windows Git Bash（OpenSSL 3.5.4、Python 3.12）下运行，systemd、包管理、下载、用户/属主均为替身。Linux 上的实际权限（例如 `remove-anytls` 后 `chmod 0750`）、端口绑定和 ACME 签发都未实测。
- `shellcheck` 本机不可用，未运行。

## 修改记录（溯源）

### 2026-11-05 — Review 修复版（新增文件，不覆盖原文件）

- 目的：修复 review 发现的问题，包括自签证书在 OpenSSL 1.1.1 上的重复扩展（高）、备份无限增长（中）、无法单独移除或重配 AnyTLS（中），以及菜单失败退出、同会话重装复用密码、交互校验过晚（低）。
- 涉及文件：新增 `install-review.sh`、`test-review.sh`、`test-review-cases.sh`、`README-review.md`。
- 验证：见上文“验证”一节。
- 未验证：见上文“未验证”一节。
- 说明：按用户要求不覆盖原文件，因此本次没有写入根 `README.md` 和 `speed-slayer-lite/README.md` 的修改记录（AGENTS.md 约定）。正式采纳并替换 `install.sh` 时，需要把本条补记到这两处，同时改回 `SCRIPT_URL`。
