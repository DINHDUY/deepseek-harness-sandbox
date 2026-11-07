# Security policy

## What this sandbox is for

`dsh` is an autonomous agent: it reads files, runs shell commands, and fetches
URLs chosen by the model. Treat every container running it as **already
compromised** and design around containing the blast radius, not preventing
compromise. The three run paths (`make sandbox-run`, `podman-compose.yml`, and
the Quadlet service) all apply the same controls:

| Control | Why |
|---|---|
| `--cap-drop=ALL`, `--security-opt=no-new-privileges` | No setuid/setgid escalation, no raw sockets, no module loading. |
| `--read-only` rootfs + tmpfs for `/tmp` | Persisted changes must land in the agent's own data volume, nowhere else. |
| Own network + own volume per run path | A dev container can never read or corrupt the production agent's state. |
| Egress blackhole routes | Blocks the LAN, the podman-machine gateway that forwards into the Mac's loopback, link-local, and every RFC1918/CGNAT range. Only the internet and `ALLOWED_HOSTS` are reachable. |
| `--no-hosts` | The container cannot read the host's `/etc/hosts`. |
| `--pids-limit`, `--memory`, `--cpus`, systemd `TasksMax`/`MemoryMax` | Contains fork bombs and memory exhaustion. |
| `npm ci --ignore-scripts`, digest-pinned base image | Dependencies cannot run code at install time, and the base cannot be silently swapped. |

## Threat model limits — read these

These controls are **not** a sandbox against a determined local attacker, and
some of them are weaker than they look:

- **Rootless Podman shares the kernel with the podman machine VM.** A container
  escape inside the VM is an escape into a user-owned VM, not into your Mac. But
  the VM has your home directory bind-mounted wherever you mount it, so **never
  bind-mount your home directory, SSH keys, or dotfiles into the container.**
- **Egress filtering is IP-level only.** Any route can allow or deny an IP
  range, never a port or a URL. The agent can reach the whole public internet, so
  it can exfiltrate anything you put in its environment or its data volume.
- **The API key is inside the container.** `DEEPSEEK_API_KEY` is readable by any
  code the agent runs. Use a spend-capped key, and rotate it if you suspect the
  agent was tricked into leaking it.
- **Keys configured in the app are stored on the data volume.** Keys are optional;
  if you enter them in the web Models page instead of exporting them, `dsh` writes
  them into `DSH_HOME/.credentials.yaml` on the data volume. Treat that volume as a
  secret store: don't back it up to unencrypted storage, and `podman volume rm` it
  when you're done.
- **The web launch token is a bearer secret.** `dsh web` prints it to stdout, so
  it lands in container logs and the systemd journal. `make sandbox-logs`,
  `make logs`, and `make quadlet-url` redact it on the way out, but the raw value
  is still in the log store. Treat `http://localhost:PORT/?token=…` like a
  password: never paste it into an issue or chat.
- **`ALLOWED_HOSTS` opens every port on that host.** It is meant for one trusted
  service (e.g. a local search proxy), not for a whole machine you also use.
- **`--security-opt mask=/proc/kcore` is cosmetic.** `/proc/kcore` already reads
  as zero bytes inside a container. `/proc/sched_debug` masking does work.
- **SELinux labels and the podman machine's own isolation** are what stop a
  container from writing outside its volume. Do not disable them.

## Reporting a vulnerability

If you find a vulnerability in this packaging (not in upstream `dsh`), open a
[private security advisory](https://github.com/your-org/deepseek-sandbox/security/advisories/new).
For upstream `dsh` issues, report to DeepSeek through its published process.

Include the podman version (`podman --version`), the run path you used, and the
exact command. Expect a response within 7 days.

## Rotating a leaked secret

```sh
# 1. Stop the agent and destroy its state (the token and history live in the volume).
make sandbox-stop SANDBOX_NAME=dsh-sandbox SANDBOX_NET=dsh-mac-net
podman volume rm deepseek-harness-dev-data

# 2. Issue a new API key at the provider and update your environment.

# 3. Restart; a fresh launch token is generated on start.
make sandbox-run
```

For the Quadlet service: `make quadlet-stop`, `podman volume rm
deepseek-harness-prod-data`, then `make quadlet-start`.
