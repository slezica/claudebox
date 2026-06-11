# claudebox

A **single self-contained script** that runs Claude Code inside a Docker
container with **every action auto-approved** — made safe by the container
boundary instead of by per-action permission prompts. Keep `claudebox.sh`
anywhere (even on your `PATH`) and run it from your project root to hand an agent
maximum autonomy within a hard safety fence.

```bash
./claudebox.sh login     # one-time: log the sandbox in (separate from your host)
./claudebox.sh           # launch Claude on the current directory, full autonomy
```

## Why this is safe

Normally Claude Code asks before each risky action — the right default on your
real machine. claudebox flips it (`--dangerously-skip-permissions` approves
everything) and moves the safety down a layer, into Docker:

| Boundary | How | What it prevents |
| --- | --- | --- |
| **Filesystem** | Only the current dir is bind-mounted to `/workspace`. The rest of your host is invisible. | Reading/altering anything outside the project. |
| **Non-root** | Runs as the unprivileged `claude` user. | Privileged writes, package-level tampering. |
| **No new privileges** | `--security-opt no-new-privileges` + `--cap-drop ALL`. | Privilege escalation / container breakout. |
| **Disposable** | `--rm`; the only persisted state is your project and the login volume. | Drift and hidden state between runs. |

Network egress is open, so the agent can install packages, hit the Claude API,
and browse the web. Tighten that later with an egress allowlist if needed.

## It works on the current directory

claudebox mounts **your current working directory** as the sandbox — so run it
from your project root, the way you'd run any dev command. The script itself can
live wherever you like; only where you *run* it matters. Inside the container
that directory is `/workspace`, and it's the only host path the agent can touch.

## Shared image, per-project sessions

The **image is shared** across every project — but it's tagged with the embedded
Dockerfile's hash. So an unchanged Dockerfile is built once and reused
everywhere, while editing it yields a new tag that rebuilds automatically. A
stale copy of the script can never silently inherit a different project's image,
and you never have to remember to rebuild. Old versions pile up as tags over
time — `./claudebox.sh clean` drops all but the current one.

The **login is per-project**: it lives in a Docker named volume (named after the
project folder) mounted at `~/.claude` inside the container — **independent of
your host login**, and remembered across runs. Override the image or volume name
with `CLAUDEBOX_IMAGE` / `CLAUDEBOX_VOLUME`.

```bash
./claudebox.sh login     # one-time OAuth device flow (approve the URL)
./claudebox.sh logout    # forget this project's session (deletes the volume)
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
./claudebox.sh build                 # force-rebuild the image
./claudebox.sh clean                 # remove stale image versions
```

## How it's built

`claudebox.sh` carries its Dockerfile inline as a quoted heredoc and builds it
from stdin with an empty context — there's no separate `Dockerfile` to keep in
sync. The image tag is the hash of that Dockerfile, so the tag always matches
what's in the script. Claude Code is installed via its native installer, and
`/workspace` is pre-trusted as a git `safe.directory` (so mounted repos work
even on hosts that preserve the mount's original UID, like native Linux).

## Requirements

- Docker (Docker Desktop on macOS/Windows, or Docker Engine on Linux).
