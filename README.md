# llama-server-autoload

Socket-activated, idle-unloading systemd user service for llama.cpp.

The server cold-starts on the first API request and auto-unloads after a configurable idle period (default 30 min).

## Usage

```bash
./setup.sh                          # defaults (MiniCPM5-2B, port 42424)
./setup.sh --model "ggml-org/gpt-oss-20b:Q4_K_M" --service gpt-oss --port 42426
./setup.sh --help                   # all options
```

## What it creates

- `~/.config/systemd/user/<service>.socket` — listens on the public port
- `~/.config/systemd/user/<service>-proxy.service` — systemd-socket-proxyd with health-gate
- `~/.config/systemd/user/<service>.service` — the actual llama-server
- `~/.config/systemd/user/<service>-idle-check.{service,timer}` — 30min idle unload
- `~/.local/bin/<service>-proxy-wait.sh` — polls `/health` before proxying
- `~/.local/bin/<service>-idle-check.sh` — idle detection logic

## How it works

```
client → :42424 (socket)
         → proxy (waits for /health, then systemd-socket-proxyd)
         → :42425 (llama-server)

idle timer (every 60s) → no connections for 30min → stop server
```

The socket stays bound at all times (~zero cost). The server process only exists while being used or within the idle window.

## Requires

- `llama-server` in PATH
- `systemd-socket-proxyd` (shipped with systemd)
- `curl`, `ss`
