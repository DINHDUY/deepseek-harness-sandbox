# DeepSeek Harness Sandbox

Rootless Podman packaging for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).
The image installs the `dsh` CLI from npm (`@deepseek-ai/dsh`) on a digest-pinned `node:24-slim`,
runs as non-root user `dshuser` (uid 10001, `nologin` shell), and starts `dsh web` on port 8080.
(The PyPI `deepseek-harness-runtime-bin` wheel resolves to an old `0.0.0.dev0` build without `--pre`,
and its web profile lacks the workspace controller, so npm is used instead.)
State lives in `DSH_HOME=/home/dshuser/data/dsh`, on a volume that is **different per run path**
(`deepseek-harness-dev-data` for the sandbox/compose paths, `deepseek-harness-prod-data` for Quadlet).

## Why do we need a sandbox?

DeepSeek Harness is an agent: a language model decides which tools to run (shell commands, file edits,
web fetches, plugins) and `dsh` executes them with the permissions of whoever started it. Run directly on
your Mac, that means:

- **Model mistakes become real damage.** A wrong `rm`, a bad edit or a runaway process hits your actual files.
- **Prompt injection.** Web pages, search results or repository files the agent reads can contain
  instructions that steer it into running commands you never intended.
- **Access to everything you can reach.** Your home directory, SSH keys, cloud credentials, browser data,
  your Mac's loopback services and the devices on your home or office network.
- **Untrusted software.** The harness and its plugins are a fast-moving preview release that pulls in many
  npm packages.

The sandbox shrinks the blast radius: the agent works inside a disposable container that holds only what
you give it, so a mistake or an attack is contained to that container instead of your Mac.

## Supply chain

`package.json` + `package-lock.json` are the source of truth for what gets installed. The build runs
`npm ci --omit=dev --ignore-scripts`, so dependency install scripts never execute and dev-only packages
never enter the image. `overrides` in `package.json` force the transitive dependencies that had published
advisories (undici, zod, fflate, `@modelcontextprotocol/client`) to patched versions; `npm ci` fails if the
lockfile disagrees with `package.json`. The base image is pinned by content digest
(`make digest-check` prints the current one). Check the tree with `make audit`; CI runs the same audit and
fails on anything high or critical.

## What makes it safe?

Defense in depth; each layer limits what happens if the one above it fails. All three run paths
(`make sandbox-run`, `podman-compose.yml`, and the Quadlet service) apply the same set.

| Layer | What it does | Where |
|-------|--------------|-------|
| VM boundary | On macOS, Podman runs containers inside a Linux VM, so an escape from the container still lands in the VM, not on macOS. | Podman machine |
| Rootless, non-root user | No root daemon; the process runs as `dshuser` (uid 10001) with a `nologin` shell, not root. | `Containerfile`, Podman |
| No capabilities | `--cap-drop=ALL` removes every Linux capability (no raw sockets, no mounting, no changing ownership). | all run paths |
| No privilege escalation | `--security-opt=no-new-privileges` blocks setuid/setgid escalation. | all run paths |
| Read-only root filesystem | `--read-only`; only `/tmp`, `~/.local` (size-capped tmpfs) and the data volume are writable, so the agent cannot alter installed software. | all run paths |
| No host files | The only mount is a named volume; no bind mounts of your home directory. `--no-hosts` keeps the VM's `/etc/hosts` out of reach. | all run paths |
| Per-path isolation | Each run path has its own network **and** volume, so a dev container can never read or corrupt the production agent's state. | `Makefile`, `podman-compose.yml` |
| Resource limits | `--memory=4g --cpus=2 --pids-limit=256`, plus systemd `MemoryMax`/`TasksMax`/`CPUQuota` for the service. | all run paths |
| Network isolation | Blackhole routes drop traffic to your LAN, the Mac's loopback (the podman-machine gateway `192.168.127.254`), link-local, and every private/CGNAT range (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`). Only hosts in `ALLOWED_HOSTS` on the LAN are reachable. | `make sandbox-net`, `compose-net`, `quadlet-net` |
| Loopback-only UI | The web UI is published on `127.0.0.1` only and needs the per-start launch token, so other devices cannot connect. | all run paths |
| Fail-closed bind | `scripts/entrypoint.sh` binds `dsh web` to the container's own interface address and refuses to start if it cannot resolve one — it can never fall back to a wildcard. | `scripts/entrypoint.sh` |
| Health + restart policy | `scripts/healthcheck.mjs` probes the address dsh actually serves; the Quadlet unit uses `HealthOnFailure=kill` and a bounded systemd restart. | `quadlet/`, `HC` in `Makefile` |
| Minimal image | No git, curl, wget, python or compilers in the runtime image, so there is less for an attacker to use. `npm`/`apt` are still present (they come with `node:24-slim`) but the agent runs as non-root, so `apt` cannot install anything. | `Containerfile` |
| Secrets stay out of the image | API keys are optional and come from your shell environment (or a `chmod 600` env file for Quadlet); if you don't set them, enter them in the web Models page after the app starts. Nothing is baked into the image or committed. | `Makefile`, `.gitignore` |

### Limits: what the sandbox does not protect

- **The internet is open.** The agent can still make outbound requests, so anything inside the container,
  including `DEEPSEEK_API_KEY`, could be sent out by a compromised or tricked agent. Use a dedicated,
  spend-limited key.
- **Allowed hosts are fully open.** Routes cannot filter by port, so every port on an `ALLOWED_HOSTS` entry is reachable.
- **The launch token is a bearer secret.** `dsh web` prints it to stdout, so it lands in container logs and
  the systemd journal. `make sandbox-logs`, `make logs` and `make quadlet-url` redact it on the way out, but
  the raw value is still in the log store. Treat the URL like a password. See [SECURITY.md](SECURITY.md).
- **Data in the volume is writable by the agent.** Anything you place in the data volume can be changed or deleted.
- **Never bind-mount your home directory, SSH keys or dotfiles.** The VM has whatever you mount, and a container
  escape inside the VM reaches it.
- **Not a hardened multi-tenant boundary.** Kernel or VM escapes are rare but possible; keep Podman and the machine image updated.

## Project layout

```
.
├── Containerfile                  # Multi-stage OCI build (deps stage + runtime stage)
├── .containerignore               # Build-context excludes
├── package.json                   # Pinned dsh version + dependency overrides
├── package-lock.json              # Lockfile used by `npm ci`
├── Makefile                       # Shortcuts (make help)
├── podman-compose.yml             # Local development (hardened, own net + volume)
├── quadlet/                       # Production: rootless systemd units
│   ├── deepseek-harness.container         # hardening + health + resource limits
│   ├── deepseek-harness-prod-data.volume  # production state (never shared with dev)
│   ├── podman-prune.service               # dangling images only (non-destructive)
│   └── podman-prune.timer
├── scripts/
│   ├── entrypoint.sh              # Binds dsh web to the container IP (wildcards rejected)
│   ├── container-ip.mjs           # Resolves that IP; exits non-zero if there is none
│   └── healthcheck.mjs            # Probes the same address from inside the container
├── .github/workflows/ci.yml       # audit, quadlet validation, lint, secret scan, build
└── SECURITY.md                    # Threat model limits, disclosure, key rotation
```

Agent state never lives in the repo: it is in named Podman volumes. Inspect it with
`podman volume inspect deepseek-harness-dev-data` (the files are inside the VM at
`~/.local/share/containers/storage/volumes/<name>/_data`).

## Build

```sh
make build
```

## Local development

API keys are **optional**. Set them in your shell to inject them at start, or leave them unset and
enter them in the web **Models** page after the app opens (the key is then stored on the data volume).

```sh
export DEEPSEEK_API_KEY=...   # optional; omit to configure in the web Models page
make up        # podman-compose up -d --build -> http://localhost:8081 (set WEB_PORT to change)
make logs      # launch token redacted
make down
```

`make up` uses port 8081 and `make sandbox-run` / `make run` use 8080, so they don't collide;
two containers cannot publish the same host port ("proxy already running"). The compose stack joins
`dsh-compose-net` with the same egress routes, and mounts `deepseek-harness-dev-data`.

## Production (rootless Quadlet)

```sh
make build
make quadlet-install     # creates deepseek-harness-net, the prune timer, and an empty env file template
make quadlet-start
loginctl enable-linger "$USER"   # start at boot without login
make quadlet-url         # browser URL with the current launch token
```

Keys are optional. `make quadlet-install` creates `~/.config/deepseek-harness/env` (chmod 600) as an
empty template if it does not exist. To supply keys at start, edit that file:

```sh
echo 'DEEPSEEK_API_KEY=...' >> ~/.config/deepseek-harness/env   # optional
```

Or skip it entirely and enter the key in the web Models page after `make quadlet-start`.

The Quadlet unit publishes `127.0.0.1:8080`, the same port `make sandbox-run` uses by default, so the two
cannot run at once ("port is already allocated"). Either stop one first (`make quadlet-stop` or
`make sandbox-stop`) or edit `PublishPort` in `quadlet/deepseek-harness.container`.

Quadlet has no `Route=` key, so the isolated network is created by `make quadlet-net` and only referenced
by name from the unit. `make validate` runs the real quadlet generator over the units and fails on any key
this Podman version does not support — run it after editing anything in `quadlet/`.

## Run the sandbox on macOS

`make sandbox-run` creates the `dsh-mac-net` network with blackhole routes to your LAN, the
podman-machine host gateway (`192.168.127.0/24`, which forwards to the Mac's loopback), link-local
`169.254.0.0/16`, and all private/CGNAT ranges. It then starts a hardened `dsh web` container
(4g RAM, 2 CPUs, 256 PIDs, all capabilities dropped, read-only rootfs, tmpfs `/tmp` and `~/.local`,
no `/etc/hosts`). The UI is published on `127.0.0.1:8080` only. The launch token changes on every container
start and the URL in the logs uses the container IP, which your Mac can't reach. Use `make sandbox-url`
(prints `http://localhost:8080/?token=...`) or `make sandbox-open`. If you see "authentication required;
reopen the URL printed by dsh web", re-run one of these after any restart.

```sh
export DEEPSEEK_API_KEY=...        # optional; never commit keys. Omit to set it in the web Models page
export EXA_API_KEY=...             # optional; DSH_WEB_SEARCH_PROVIDER defaults to exa
make sandbox-run LAN_SUBNET=192.168.1.0/24   # use your router's subnet
make sandbox-logs                  # token redacted
make sandbox-stop
```

`--userns=keep-id` is not used on macOS (Podman runs in a Linux VM).

Notes: routes are fixed when the network is created, so run `make sandbox-stop` before changing
`LAN_SUBNET`/`BLOCKED_SUBNETS`/`ALLOWED_HOSTS`.

The sandbox may reach only the LAN hosts in `ALLOWED_HOSTS` (default `192.168.1.219`; the
`/32` route is more specific than the LAN blackhole). Routes can't filter by port, so every
port on that host is reachable, not just `:3000`; use `ALLOWED_HOSTS="a b"` for several hosts.
Blocking `10.0.0.0/8` does not break the sandbox: its own subnet keeps a more specific connected
route, so its gateway, published ports and internet access all still work — the range is blocked to
stop lateral movement into the default `podman` bridge (`10.88.0.0/16`) and other containers.
`--no-hosts` only hides the VM's `/etc/hosts` entries (including `host.containers.internal`); it does not
block network access.

## Sizing the podman machine

The container limits (`--memory=4g --cpus=2`) are only meaningful if the VM is bigger than they are.
Check with `podman machine inspect podman-machine-default --format '{{.Resources.CPUs}} CPU / {{.Resources.Memory}} MiB'`.
This machine is 5 CPU / 6 GiB, which leaves ~2 GiB of headroom for the VM itself and the Quadlet
service's `MemoryMax=5G` — if you raise the container limits, raise the machine with
`podman machine set --memory <MiB> --cpus <N>` and restart it. A container that hits its memory limit is
OOM-killed inside the VM, not swapped onto your Mac.

Volumes have no quota by default: the agent can fill the machine's 100 GiB disk. If that matters, cap it
at the filesystem level (create the volume with `--opt o=...` on a loop device, or monitor with
`podman system df`) rather than assuming `--read-only` limits writes — the data volume is writable by design.

## Maintenance

```sh
make audit          # npm audit on the pinned tree (dev deps excluded)
make digest-check   # current base-image digests for the Containerfile pin
make validate       # run the real quadlet generator over quadlet/
make prune          # dangling images + build cache only (keeps tagged images)
make prune-all      # ALL unused images, including base images (asks first)
```

The weekly systemd timer runs the non-destructive `make prune` equivalent, never `prune -a`, so the base
image and your built image always survive it.

## Conventions

- Fully qualified image names; `Containerfile` / `.containerignore` naming.
- Runtime image has no git/curl/wget/python/compilers (only node, npm, and the base apt tooling).
- Volume names follow `{project}-{service}-{type}` and are never shared between run paths
  (`deepseek-harness-dev-data`, `deepseek-harness-prod-data`).
- Run `make help` for all targets and the current value of every variable.
