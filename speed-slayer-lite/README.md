# Speed Slayer Lite

只部署三种 Xray 入站，不安装 Nginx，不提供 HTTP 订阅：

- VMess + WebSocket + Cloudflare Tunnel
- Shadowsocks 2022 (`2022-blake3-aes-128-gcm`)
- VLESS + TCP + REALITY + Vision

## 端口

| 默认端口 | 监听地址 | 用途 | 防火墙 |
| --- | --- | --- | --- |
| `30000/tcp` | `127.0.0.1` | VMess WebSocket 源站 | 不开放 |
| `30001/tcp+udp` | `0.0.0.0` / `[::]` | Shadowsocks 2022 | 开放 |
| `30002/tcp` | `0.0.0.0` / `[::]` | VLESS REALITY | 开放 |

`cloudflared` 还需要出站访问 Cloudflare，通常为 `7844/tcp+udp`，失败时可回退到 `443/tcp`。

## 安装

支持 Debian 11+、Ubuntu 20.04+，架构为 amd64 或 arm64。必须用 root 执行。

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
  REALITY_SERVER_NAME=learn.microsoft.com \
  bash install.sh install
```

安装完成后，连接信息只写到 `/etc/speed-slayer-lite/client-info.txt`，权限 `0600`：

```bash
sudo speed-slayer-lite show
sudo speed-slayer-lite status
sudo speed-slayer-lite repair-argo
sudo speed-slayer-lite uninstall
```

Quick Tunnel 域名可能在首次启动后数秒才出现。再次执行 `speed-slayer-lite show` 会刷新 VMess 链接。
`repair-argo` 会重启 Xray 和 cloudflared，等待新的 Quick Tunnel 域名，并输出更新后的 VMess 链接。Quick Tunnel 修复后必须在客户端重新导入该链接。

VMess 链接中 `add` 默认是 `www.wto.org`，`host` 和 `sni` 仍然是当前 Tunnel 域名。这样要求 `www.wto.org` 在你的网络环境中解析到可用的 Cloudflare 边缘地址；如果客户端连不上，将 `VMESS_ADDRESS` 改为当前 Tunnel 域名：

```bash
sudo VMESS_ADDRESS='你的-tunnel.trycloudflare.com' bash install.sh show
```

如果你使用的是命名 Tunnel，也可以把 `VMESS_ADDRESS` 设为你自己的 Cloudflare 域名。`add`、`host`、`sni` 不是同一个字段，不能只把 `host/sni` 改成 `www.wto.org`。

## 防火墙

脚本不会修改防火墙。按你的 SSH 来源限制管理端口，并只开放：

```bash
ufw allow 30001/tcp
ufw allow 30001/udp
ufw allow 30002/tcp
```

不要开放 `30000`。它只供本机 `cloudflared` 访问。

## 安全设计

- Xray 和 cloudflared 使用独立低权限账户。
- systemd 服务启用基础沙箱和资源限制。
- 固定 Xray/cloudflared 版本，并校验 SHA-256。
- UUID、SS 密钥、REALITY 私钥和 Tunnel token 均为 root-only。
- 无 Nginx、无 Web 面板、无订阅 URL。
- 安装前检查端口冲突；参数只接受受限格式，不使用 `source` 或 `eval`。

更新二进制版本时，必须同时更新 `install.sh` 中对应架构的 SHA-256。

## Cloudflare 说明

Quick Tunnel 适合测试，不保证长期域名稳定，也不支持 SSE。长期使用请选择命名 Tunnel。

- [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- [Tunnel 防火墙要求](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
