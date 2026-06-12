# claudebox

A **single self-contained script** that runs Claude Code inside a **persistent
Docker sandbox** with **every action auto-approved**. The agent gets a real,
durable dev box — it can install whatever it needs (apt packages, language
toolchains, ffmpeg…) and those installs stick between runs — while the container
keeps the blast radius off your host.

```bash
./claudebox.sh login     # one-time: log the sandbox in (separate from your host)
./claudebox.sh           # launch Claude on the current directory, full autonomy
```

## What it protects — and what it doesn't

claudebox flips Claude Code's usual per-action prompts (`--dangerously-skip-permissions`
approves everything) and moves the safety into Docker. Be clear-eyed about the
threat model:

**It protects your host and your data from an agent that errs, loops, or runs
wild.** Only the current directory is mounted, so nothing else on your machine is
reachable; no Docker socket is exposed, so the agent can't drive Docker; and the
Claude CLI runs as a non-root user. A mistake stays in the box.

**It is *not* hardened against a deliberately malicious repository.** Inside the
sandbox the agent has passwordless `sudo` (so it can install software) and open
network egress. A hostile payload could misuse both *within* the container —
including exfiltrating anything in it. **Point claudebox at code you trust.**

> Want adversary-grade isolation? That's a different tool — add an egress
> allowlist firewall and/or a stronger runtime (gVisor, a microVM). claudebox
> deliberately optimizes for *your* agent on *your* code.

## It works on the current directory

claudebox mounts **your current working directory** as the sandbox — so run it
from your project root, the way you'd run any dev command. The script itself can
live wherever you like; only where you *run* it matters. Inside the container
that directory is `/workspace`, and it's the only host path the agent can touch.

## A persistent box per project — install anything, it sticks

Each project gets its own **long-lived container**. The agent works as a non-root
user with passwordless `sudo`, so it can provision itself on demand:

```bash
sudo apt-get install -y ffmpeg        # the agent runs this itself, mid-session
curl https://sh.rustup.rs -sSf | sh   # user-space toolchains work too
```

Because the container isn't thrown away between runs, those installs persist. No
need to anticipate toolchains or maintain a Dockerfile per project — the agent
sets up what it needs and it's there next time.

- `./claudebox.sh stop` — stop the box (state preserved, frees RAM); next run restarts it.
- `./claudebox.sh reset` — delete the box for a clean slate; next run rebuilds it.

The box drifts from the recipe over time (that's the point — it's for
exploration). Anything you want *reproducible* still belongs in the Dockerfile;
`reset` always gets you back to a clean image.

## Shared image, per-project login

The **image is shared** across every project — but it's tagged with the embedded
Dockerfile's hash. So an unchanged Dockerfile is built once and reused
everywhere, while editing it yields a new tag. (An existing box pins the image it
was built from, so a recipe change won't silently erase your installs — you'll be
told to `reset` when you want to adopt it.) `./claudebox.sh clean` drops stale
image tags.

The **login is per-project**: it lives in a Docker named volume (named after the
project folder) mounted at `~/.claude` — **independent of your host login**, and
remembered across runs. Override names with `CLAUDEBOX_IMAGE`, `CLAUDEBOX_VOLUME`,
or `CLAUDEBOX_CONTAINER`.

```bash
./claudebox.sh login     # one-time OAuth device flow (approve the URL)
./claudebox.sh logout    # forget the login (also removes the box, which holds it open)
```

## It still feels like your Claude

The sandbox should change *what Claude can do*, not *who Claude is*. So claudebox
brings in the **portable** parts of your host config, **read-only**:

- **`~/.claude/CLAUDE.md`** — your global instructions.
- **`~/.claude/agents/`** — your custom subagents.

Read-only means the agent can read your config but can never alter it. Set
`CLAUDE_CONFIG_DIR` if your host config lives elsewhere, or
`CLAUDEBOX_NO_HOST_CONFIG=1` to import nothing.

Deliberately **left out**: `settings.json` (mostly host-coupled — statusline
shell commands, plugins, permissions that don't apply in the sandbox; let
sandbox-Claude configure its own, which persists in the volume), your
`projects/` history, and your credentials (the sandbox keeps its own per-project
login). The result is your Claude's *judgment* without your host's *baggage*.

## Usage

```bash
./claudebox.sh                       # launch Claude on the current dir
./claudebox.sh "fix the failing test in foo.py"   # one-shot prompt
./claudebox.sh shell                 # poke around inside the sandbox
./claudebox.sh stop                  # stop the box (state preserved)
./claudebox.sh reset                 # delete the box for a clean slate
./claudebox.sh build                 # force-rebuild the image
./claudebox.sh clean                 # remove stale image versions
```

## How it's built

`claudebox.sh` carries its Dockerfile inline as a quoted heredoc and builds it
from stdin with an empty context — there's no separate `Dockerfile` to keep in
sync. The image tag is the hash of that Dockerfile, so the tag always matches
what's in the script. Claude Code is installed via its native installer; the
`claude` user gets passwordless `sudo`; and `/workspace` is pre-trusted as a git
`safe.directory` (so mounted repos work even on hosts that preserve the mount's
original UID, like native Linux). At runtime the container's PID 1 is a
keep-alive (`sleep infinity`) and each command is `docker exec`'d into it.

## Requirements

- Docker (Docker Desktop on macOS/Windows, or Docker Engine on Linux).
