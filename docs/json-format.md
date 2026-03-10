# JSON Import / Export Format

CloudDaemon exports both VPS profiles and pinned managed services in one JSON file.

## Top-Level Shape

```json
{
  "version": 1,
  "exported_at": "2026-03-10T13:00:00Z",
  "servers": [],
  "managed_services": []
}
```

## Server Entry

```json
{
  "id": "server-1",
  "name": "Tokyo VPS",
  "base_url": "https://example.com:8443",
  "token": "long-random-agent-token"
}
```

## Managed Service Entry

```json
{
  "id": "managed-1",
  "server_id": "server-1",
  "service_name": "nginx.service",
  "pinned_at": "2026-03-10T13:10:00Z"
}
```

## Import Rules
- Exact duplicate servers are skipped.
- If an imported server ID collides with a different existing server, a new local ID is generated.
- Managed services are deduplicated by `server_id + service_name`.
- Managed services pointing to missing servers are rejected and counted as import errors.
- Exported files include tokens and should be treated as sensitive secrets.
