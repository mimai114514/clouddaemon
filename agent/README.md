# CloudDaemon Agent

## Build
```powershell
go build -o clouddaemon-agent.exe .\cmd\clouddaemon-agent
```

## Linux build
```powershell
$env:GOOS="linux"
$env:GOARCH="amd64"
go build -o clouddaemon-agent .\cmd\clouddaemon-agent
```

## Run
```bash
sudo ./clouddaemon-agent -config /etc/clouddaemon/config.yaml
```

The agent expects:
- a YAML config file
- HTTPS certificate and key files
- root privileges for `systemctl` and `journalctl`

## API
- `GET /api/v1/ping`
- `GET /api/v1/services`
- `GET /api/v1/services/{name}`
- `POST /api/v1/services/{name}/actions`
- `GET /api/v1/services/{name}/logs`
- `GET /api/v1/ws/logs?service={name}`
