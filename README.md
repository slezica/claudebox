# claudebox

Run Claude Code as a fully autonomous agent inside a persistent, resettable Docker sandbox.

- **One file** — a self-contained script; keep it in your `PATH` or repository.
- **Auto-permissions** — runs with `--dangerously-skip-permissions`; the container is the guardrail.
- **Scoped to the project** — mounts your working dir as `/workspace`.
- **Per-project container** — a long-lived container per project, with a persistent file-system.
- **Per-project login** — its own Claude login, independent of your host, remembered across runs.
- **Self-provisioning** — the agent has `sudo` and network access, so it installs whatever it needs.
- **Your config, read-only** — imports your `~/.claude/CLAUDE.md` and `~/claude/agents/`.

> **Security:** claudebox guards against a *clumsy* agent, not a *malicious* one. It keeps mistakes from escaping the container; it does not contain a deliberately hostile agent or repository. Use an agent you trust with code you trust.

## Installation

Requires [Docker](https://www.docker.com/products/docker-desktop/) (Desktop on macOS/Windows, Engine on Linux).

```bash
cp claudebox.sh ~/bin/ && chmod +x ~/bin/claudebox.sh   # anywhere on your PATH
claudebox.sh                                            # first run builds the image + signs you in
```

## Usage

Run it from your project root — claudebox always acts on the current directory.
It's a transparent wrapper: anything you pass goes straight to Claude Code.

```bash
claudebox.sh                    # launch Claude on the current dir
claudebox.sh -p "fix the bug"   # any claude flags pass through (-p = headless)
claudebox.sh config ls          # so do claude's own subcommands
claudebox.sh --help             # claudebox's help, then Claude Code's
```

The one parked word is `container`, for managing the sandbox itself:

```bash
claudebox.sh container shell    # bash shell inside the box
claudebox.sh container stop     # stop the box (state kept, frees RAM)
claudebox.sh container reset    # delete the box for a clean slate (login kept)
claudebox.sh container build    # rebuild the image
claudebox.sh container clean    # remove stale image versions
claudebox.sh container create --port <spec> --dir <spec> # forward ports / add dirs
```

Ports and extra directories are fixed when the box is created, so `container create` recreates it — **preserving the file-system**. 

In `conatiner create` both arguments are in `host[:container]` form —- `--port 8080:80`, `--dir ../lib:/src/lib`. If no container part is given, ports default to themselves and dirs are placed in `/mnt/<name>`.


If `claudebox` updates and the Dockerfile changes, a warning will prompt for a full recreation.

| Variable | Effect |
| --- | --- |
| `CLAUDE_CONFIG_DIR` | Where your host Claude config lives (default `~/.claude`). |
| `CLAUDEBOX_NO_HOST_CONFIG=1` | Import none of your host config. |
| `CLAUDEBOX_IMAGE` · `CLAUDEBOX_VOLUME` · `CLAUDEBOX_CONTAINER` | Override the generated resource names. |

## Isolation level

**The agent can reach:**

- The current working directory — mounted read-write at `/workspace`.
- Your `~/.claude/CLAUDE.md` and `~/.claude/agents/` — mounted **read-only**.
- The network — open egress.

**The agent cannot reach:**

- Anything else on your host filesystem — it isn't mounted.
- The Docker socket — it can't drive Docker or the host.
- Your host login, settings, or history — the box keeps its own.

Inside the box the agent runs as a non-root user with `sudo`; that root stays bounded by the container.
