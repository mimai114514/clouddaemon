# CloudDaemon Deployment

## Go Agent
Build the Linux binary on your target platform or with cross-compilation:

```powershell
cd agent
go build -o clouddaemon-agent ./cmd/clouddaemon-agent
```

Copy the binary and a config file based on [`agent/config.example.yaml`](../agent/config.example.yaml) to the server.

Generate or provide a TLS certificate and key. The browser connects directly to the agent, so HTTPS/WSS is required.

Run the agent:

```bash
sudo ./clouddaemon-agent -config /etc/clouddaemon/config.yaml
```

Suggested `systemd` service:

```ini
[Unit]
Description=CloudDaemon agent
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/clouddaemon-agent -config /etc/clouddaemon/config.yaml
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
```

Open the HTTPS port in your firewall, then test:

```bash
curl -k \
  -H "Authorization: Bearer YOUR_TOKEN" \
  https://YOUR_HOST:8443/api/v1/ping
```

## Flutter PWA
Build the web app:

```powershell
cd web
flutter build web
```

Deploy the contents of `web/build/web/` to Nginx, Caddy, an object storage bucket, or any other static hosting target.

If you use Nginx, make sure the site serves `index.html` for unknown routes.

## Browser Flow
1. Open the deployed PWA.
2. Add a VPS with name, agent URL, and token.
3. Open the server catalog and search for services.
4. Add selected services to the managed list.
5. Use start, stop, restart, recent logs, and tail logs from the web UI.
