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

## Architecture

```
client → :42424 (socket, always bound, ~zero cost)
         → proxy (waits for /health, then systemd-socket-proxyd)
         → :42425 (llama-server, only exists while in use)

idle timer (every 60s) → no connections for 30min → stop server
```

## Why it's designed this way

### Why socket activation instead of just `Restart=always`?

A 2B Q4 model uses ~1.5GB RAM. A 20B model can use 12GB+. Keeping a model resident
in memory 23 hours a day when you only use it 30 minutes a day is wasteful. Socket
activation is the native systemd mechanism for "start the service when someone
actually connects." The `.socket` unit just holds a listening file descriptor —
negligible memory and CPU cost.

### Why `systemd-socket-proxyd` and not native socket activation?

Ideally you'd pass the listening socket directly to `llama-server` via
`LISTEN_FDS` (standard systemd socket activation). However, `llama-server` does not
support `LISTEN_FDS` — it always calls `bind()`/`listen()` itself. There's an open
GitHub issue about this.

`systemd-socket-proxyd` solves this: it's a tiny proxy that *does* accept the
inherited socket from systemd, and for each incoming connection it opens a TCP
connection to the real backend port. The client talks to port A, proxyd forwards
to port B where llama-server is listening.

### Why `Accept=no` (the default)?

The man page explicitly states `systemd-socket-proxyd` is designed for
`Accept=no` with an event-driven design that scales better than spawning a new
process per connection. With `Accept=yes` you'd get a new proxyd process per
connection, and it actually errors out because it expects the *listening* socket,
not a per-connection socket.

### Why a health-check wrapper script?

`llama-server` opens its TCP port *before* the model finishes loading. During
loading it returns HTTP 503. If the proxy forwarded a request during this window,
the client would get a 503 or a partial response.

The wrapper script (`<service>-proxy-wait.sh`) polls `GET /health` on the backend
port until it returns `{"status":"ok"}`, then `exec`s into `systemd-socket-proxyd`.
The client's TCP connection to the public port is held open by the socket unit
during this wait, so they just see a slow first response on cold start rather than
a connection refused or a 503.

### Why a separate idle timer instead of `--exit-idle-time`?

`systemd-socket-proxyd` has a `--exit-idle-time` flag that makes it exit when no
connections are active. But that only stops the *proxy* — `llama-server` would keep
running in the background with the model loaded. We need to stop the actual server
to free the model from RAM.

A systemd timer running every 60s gives us a simple, observable, debuggable
mechanism. The script checks for established TCP connections on the backend port.
If none for the configured idle period, it stops the service. The socket remains
bound, so the next request re-triggers the whole chain.

### Why check TCP connections instead of log timestamps?

LLM APIs are stateless HTTP — a request comes in, gets a response, connection
closes. There's no persistent session. Checking for established TCP connections
on the backend port is the most direct signal that someone is actively using the
model right now. Log file mtime could work too but is more fragile (log rotation,
buffering, log level changes).

### Why `Nice=-10`?

A 2B model on CPU does ~50 tok/s. Without a nice priority boost, background
system tasks or other CPU-hungry processes can cause stutter in token generation.
`Nice=-10` gives the server priority over most user processes without being
aggressive. Adjust or remove if you run multiple models or CPU-intensive work.

### Why `--flash-attn`?

Flash attention avoids materializing the full N×N attention matrix, reducing
KV cache memory. It's mathematically identical to standard attention (no quality
loss). For short contexts (8K) the difference is negligible. For long contexts
(32K+) it's a meaningful memory reduction and can actually be *faster* due to
less memory bandwidth. Safe to always enable.

### Why hardcode thread count instead of `$(nproc - 2)`?

systemd `ExecStart` does not perform shell expansion. `$(nproc - 2)` is passed
literally to the binary as the string `$(nproc - 2)`, which llama-server can't
parse. The setup script computes the value at generation time and bakes it in.
If you change your CPU count, re-run the script.

### Why no `After=network-online.target`?

The `-hf` flag downloads the model on first run, but after that it's cached in
`~/.cache/huggingface/`. The service binds to `127.0.0.1` only — no external
network needed. Adding a network dependency would delay startup for no benefit
in the common (cached) case.

### Why `--no-webui`?

The built-in web UI is a nice demo but adds startup time and exposes an extra
attack surface on loopback. If you only use the API (which you probably do via
your LLM client), disable it. Add `--webui` back to the service unit if you want
the browser playground.

### Why `Requires=` not `Wants=` in the proxy unit?

If `llama-server` fails to start (bad model name, OOM, etc.), we want the proxy
to fail too rather than accepting connections and immediately erroring. `Requires=`
means "if the dependency is stopped, stop me; if it fails to start, fail me."
This gives the client a clean connection-refused instead of a confusing proxy error.

### Why a timer every 60s instead of a longer interval?

The idle check is cheap (one `ss` call, one file read). Checking every 60s means
the worst-case "extra time the model stays loaded" is 30 min + 60s. Checking less
frequently (say every 5 min) would be fine too but the timer cost is zero either
way. 60s just makes the idle timestamp more precise if you ever want to log
activity patterns.

## Requires

- `llama-server` in PATH
- `systemd-socket-proxyd` (shipped with systemd ≥ 233)
- `curl`, `ss`

## Uninstall

```bash
systemctl --user disable --now <service>.socket <service>-idle-check.timer
rm ~/.config/systemd/user/<service>{,.socket,-proxy.service,-idle-check.{service,timer}}
rm ~/.local/bin/<service>-{proxy-wait,idle-check}.sh
systemctl --user daemon-reload
```
