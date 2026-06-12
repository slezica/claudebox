# claudebox

Run Claude Code as a fully autonomous agent inside a persistent, resettable Docker sandbox.

claudebox launches Claude Code with every action auto-approved and confines it to a container, so the sandbox is the boundary instead of a permission prompt.

- **Auto-approved** — runs with `--dangerously-skip-permissions`; the container is the guardrail, not prompts.
- **Scoped to the current directory** — mounts your working dir as `/workspace`, the only host path the agent sees.
- **Persistent per-project box** — a long-lived container per project; installed packages and toolchains survive between runs.
- **Self-provisioning** — the agent has passwordless `sudo` and network access, so it installs whatever it needs.
- **Per-project login** — its own Claude login, independent of your host, remembered across runs.
- **Your config, read-only** — imports your `~/.claude/CLAUDE.md` and `agents/` so it behaves like your Claude, without altering them.
- **One file** — a self-contained script; keep it on your `PATH` or in the repo.

> **Scope:** claudebox guards against a *clumsy* agent, not a *malicious* one. It keeps mistakes from escaping the container; it does not contain a deliberately hostile repository. Point it at code you trust.

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
```

Signing out is Claude Code's own `/logout`, from inside a session.

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
