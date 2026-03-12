# Agent 部署指南（自签证书）

本文说明如何把 CloudDaemon 的 Go agent 部署到一台 Linux VPS，并使用自签证书提供 `HTTPS/WSS` 服务。

由于 CloudDaemon 的 Web 端是浏览器直接连接 agent，所以证书必须被浏览器信任；否则即使 agent 已启动，前端也无法正常访问接口和日志 WebSocket。

## 1. 前提条件
- VPS 使用 `systemd`
- 具有 `root` 或可执行 `sudo` 的权限
- 已拿到 Linux `amd64` 产物
- 计划给 agent 分配一个可访问的域名或固定 IP

如果你还没有编译产物，可以先在本地执行：

```powershell
.\build-agent-linux-amd64.ps1
```

默认输出文件：

```text
agent/dist/clouddaemon-agent
```

## 2. 上传文件到服务器
建议在服务器上使用如下目录：

```text
/opt/clouddaemon/clouddaemon-agent
/etc/clouddaemon/config.yaml
/etc/clouddaemon/tls.crt
/etc/clouddaemon/tls.key
```

示例：

```bash
sudo mkdir -p /opt/clouddaemon /etc/clouddaemon
sudo chown -R root:root /opt/clouddaemon /etc/clouddaemon
sudo chmod 755 /opt/clouddaemon /etc/clouddaemon
```

把以下文件上传到服务器：
- agent 可执行文件
- 基于 [config.example.yaml](../agent/config.example.yaml) 修改后的配置文件

## 3. 生成自签证书
如果你使用域名，例如 `agent.example.com`，建议证书的 `CN` 和 `subjectAltName` 都写这个域名。

示例命令：

```bash
sudo openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout /etc/clouddaemon/tls.key \
  -out /etc/clouddaemon/tls.crt \
  -subj "/CN=agent.example.com" \
  -addext "subjectAltName=DNS:agent.example.com"
```

如果你只能通过 IP 访问，例如 `203.0.113.10`：

```bash
sudo openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout /etc/clouddaemon/tls.key \
  -out /etc/clouddaemon/tls.crt \
  -subj "/CN=203.0.113.10" \
  -addext "subjectAltName=IP:203.0.113.10"
```

设置权限：

```bash
sudo chmod 600 /etc/clouddaemon/tls.key
sudo chmod 644 /etc/clouddaemon/tls.crt
sudo chmod +x /opt/clouddaemon/clouddaemon-agent
```

## 4. 配置 agent
示例配置：

```yaml
listen_addr: ":8443"
tls_cert_file: "/etc/clouddaemon/tls.crt"
tls_key_file: "/etc/clouddaemon/tls.key"
admin_token: "请替换为长随机字符串"
allowed_origins:
  - "https://your-pages-domain.pages.dev"
log_tail_default_lines: 200
```

配置建议：
- `admin_token` 使用足够长的随机字符串
- `allowed_origins` 填你的 Web 端真实访问域名(尾部不要带/)
- 如果 Web 端会同时从多个域名访问，就把这些域名都加进去

## 5. 创建 systemd 服务
创建文件：

```bash
sudo tee /etc/systemd/system/clouddaemon-agent.service >/dev/null <<'EOF'
[Unit]
Description=CloudDaemon agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/clouddaemon/clouddaemon-agent -config /etc/clouddaemon/config.yaml
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
```

启用并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now clouddaemon-agent
sudo systemctl status clouddaemon-agent
```

## 6. 放行端口
如果 agent 监听 `8443`，请在系统防火墙和云厂商安全组中放行这个端口。

例如使用 `ufw`：

```bash
sudo ufw allow 8443/tcp
```

## 7. 验证 agent
先用 `curl` 测试接口：

```bash
curl -k \
  -H "Authorization: Bearer 你的token" \
  https://agent.example.com:8443/api/v1/ping
```

返回示例：

```json
{
  "hostname": "vps-01",
  "now": "2026-03-10T14:00:00Z",
  "systemd_available": true,
  "version": "1.0.0"
}
```

## 8. 让浏览器信任自签证书
这是最关键的一步。

因为 Web 端是浏览器直接连接 agent，如果浏览器不信任这个自签证书：
- `https` 接口请求会失败
- `wss` 日志追尾也会失败
- 页面里通常会表现为“连接失败”或证书错误

你至少需要完成其中一种方式：

### 方式 A：把证书导入本机信任列表
把 `/etc/clouddaemon/tls.crt` 下载到你访问 Web 端的电脑，然后导入系统或浏览器信任证书列表。

适合：
- 自己个人使用
- 固定几台设备访问

### 方式 B：先手动打开 agent 地址并确认风险
先在浏览器直接打开：

```text
https://agent.example.com:8443/api/v1/ping
```

手动接受证书风险页后，再回到 CloudDaemon Web 页面测试。

说明：
- 某些浏览器/系统环境下，这种方式不一定对 WebSocket 长期稳定
- 更稳妥的方式仍然是把证书导入受信任列表

## 9. Web 端接入
在 CloudDaemon Web 页面里新增服务器时填写：
- 名称：例如 `Tokyo VPS`
- Agent URL：例如 `https://agent.example.com:8443`
- Token：与 `config.yaml` 中的 `admin_token` 一致

之后就可以：
1. Ping 服务器
2. 浏览全部 systemd 服务
3. 搜索服务并加入管理列表；收藏按服务名全局生效
4. 启停重启服务
5. 查看最近日志和实时追尾

## 10. 常见问题
### 浏览器提示证书错误
优先检查：
- 域名/IP 是否与证书中的 `CN` / `subjectAltName` 一致
- 访问设备是否已经信任这张证书
- Web 端填写的 Agent URL 是否和证书匹配

### Web 能打开，但日志追尾失败
优先检查：
- 浏览器是否信任自签证书
- `allowed_origins` 是否包含 Web 端域名
- `8443` 端口是否可达

### agent 启动失败
查看：

```bash
sudo journalctl -u clouddaemon-agent -n 200 --no-pager
```

重点检查：
- 配置文件路径是否正确
- 证书和私钥是否存在
- 私钥权限是否可读

## 11. 更推荐的长期方案
自签证书适合个人自托管、测试环境或少量设备使用。

如果后续需要更稳定的跨设备访问，推荐改成：
- 给 agent 配正式域名
- 使用受信任 CA 证书
- 或者让 Nginx / Caddy 反代 HTTPS，再由 agent 仅监听本地端口
