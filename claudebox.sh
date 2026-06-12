#!/usr/bin/env bash
#
# claudebox — run Claude Code in a persistent Docker sandbox with full autonomy.
#
# A single self-contained script. Keep it anywhere (even on your PATH); it
# operates on your CURRENT DIRECTORY, so run it from your project root:
#
#   claudebox.sh                 Launch Claude on the current dir (auto-permissions)
#   claudebox.sh login           One-time login; persists in the sandbox
#   claudebox.sh build           Force-(re)build the sandbox image
#   claudebox.sh shell           Drop into a bash shell inside the sandbox
#   claudebox.sh stop            Stop the sandbox (state preserved; frees RAM)
#   claudebox.sh reset           Delete the sandbox container (clean slate)
#   claudebox.sh logout          Reset the sandbox and forget the login
#   claudebox.sh clean           Remove stale image versions
#   claudebox.sh <prompt...>     Run Claude with a one-shot prompt
#
# The sandbox is a long-lived container, one per project. Claude runs as a
# non-root user but has passwordless sudo, so it can install whatever it needs
# (apt packages, language toolchains, ffmpeg, …) on demand — and because the
# container persists between runs, those installs stick.
#
# THREAT MODEL — read this. claudebox protects your HOST and your DATA from an
# agent that errs, loops, or runs wild: only the current directory is mounted,
# so nothing else on your machine is reachable, and no Docker socket is exposed.
# It is NOT hardened against a deliberately malicious repository — inside the box
# the agent has root and open network. Point it at code you trust.

set -euo pipefail

# claudebox operates on the current working directory: that is the ONLY part of
# the host filesystem the container can see. Run it from your project root.
PROJECT_ROOT="$(pwd)"

sha_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
}

# Slugify the project folder name for human-readable resource names.
slug="$(basename "${PROJECT_ROOT}" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
[ -n "${slug}" ] || slug="project"

# Where the user's host Claude config lives. We import the *portable* bits of it
# read-only so the sandbox feels like their Claude (see ensure_container), but
# never settings.json, history, or credentials. Set CLAUDEBOX_NO_HOST_CONFIG=1
# to import nothing.
HOST_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

# Embedded Dockerfile. Read into a variable with a QUOTED heredoc delimiter so
# the shell does not expand ${USERNAME}/$PATH/$HOME — Docker must see them raw.
# Holding it in a var lets us both hash it and pipe it to `docker build`.
# (read -d '' returns non-zero at EOF, hence "|| true" under `set -e`.)
read -r -d '' DOCKERFILE <<'__DOCKERFILE__' || true
# Claude Code agent sandbox. The container is the boundary: only the project is
# mounted in, so even though the agent has root *inside* the box (via sudo) it
# can't reach your host. This protects against accidents and runaway behavior,
# not against a deliberately malicious repo.
FROM node:22-slim

# Base tooling, plus sudo so the agent can install more on demand.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep jq less sudo \
  && rm -rf /var/lib/apt/lists/*

# Non-root user with passwordless sudo. The agent works as `claude` and escalates
# only when it needs to install system packages — keeping the Claude CLI itself
# non-root (it refuses to run as root) while still being able to provision.
ARG USERNAME=claude
RUN useradd --create-home --shell /bin/bash "${USERNAME}" \
  && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
  && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install Claude Code via the native installer (no global npm). Binary lands in
# ~/.local/bin; config + credentials live in ~/.claude.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# Keep ALL of Claude's state inside ~/.claude — config, credentials, sessions,
# and the main state file. By default that file is ~/.claude.json in $HOME,
# OUTSIDE the mounted volume, so login and config would reset on every run.
# Pinning the config dir into ~/.claude keeps everything on the volume.
ENV CLAUDE_CONFIG_DIR="/home/${USERNAME}/.claude"

# Trust the bind-mounted repo. Without this, on hosts where the mount keeps its
# host UID (e.g. native Linux), git aborts with "dubious ownership" because the
# repo owner != the container user.
RUN git config --global --add safe.directory /workspace

# The config dir (and thus the persistent volume mounted over it) holds the
# login, config, and session history — so they survive across runs.
RUN mkdir -p /home/${USERNAME}/.claude

WORKDIR /workspace
CMD ["claude", "--dangerously-skip-permissions"]
__DOCKERFILE__

# Tag the image with the Dockerfile's hash: identical recipes share one image,
# and any edit yields a new tag that rebuilds automatically instead of silently
# reusing a stale image.
IMAGE="${CLAUDEBOX_IMAGE:-claudebox:$(printf '%s' "${DOCKERFILE}" | sha_stdin | cut -c1-12)}"

# The persistent sandbox container, one per project. The name includes a hash of
# the FULL project path so two projects that share a folder name can't collide
# onto the same container (which would silently edit the wrong project's files).
CREDS_VOLUME="${CLAUDEBOX_VOLUME:-claudebox-${slug}-creds}"
CONTAINER="${CLAUDEBOX_CONTAINER:-claudebox-${slug}-$(printf '%s' "${PROJECT_ROOT}" | sha_stdin | cut -c1-8)}"

build_image() {
  echo "→ Building image '${IMAGE}'"
  printf '%s' "${DOCKERFILE}" | docker build -t "${IMAGE}" -
}

ensure_image() {
  docker image inspect "${IMAGE}" >/dev/null 2>&1 || build_image
}

# Resolve the sandbox to a running container, creating it on first use. The
# container persists between runs, so anything the agent installs sticks.
ensure_container() {
  ensure_image
  if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    # The container pins the image it was built from. If the recipe has changed
    # since, don't silently recreate — that would erase the agent's installs.
    # Warn and keep working; adopting the new recipe is an explicit `reset`.
    local cur_img
    cur_img="$(docker container inspect -f '{{.Config.Image}}' "${CONTAINER}")"
    if [ "${cur_img}" != "${IMAGE}" ]; then
      echo "⚠ Sandbox was built from an older recipe (${cur_img}); installs are"
      echo "  preserved. Rebuild clean from the current recipe: ./claudebox.sh reset"
    fi
    if [ "$(docker container inspect -f '{{.State.Running}}' "${CONTAINER}")" != "true" ]; then
      docker start "${CONTAINER}" >/dev/null
    fi
  else
    # Bring the user's host config into the sandbox so it feels like their Claude
    # — read-only, portable bits only (global CLAUDE.md and custom agents/).
    # settings.json, history, and credentials are deliberately left out.
    local -a host_config=()
    if [ -z "${CLAUDEBOX_NO_HOST_CONFIG:-}" ]; then
      [ -f "${HOST_CLAUDE_DIR}/CLAUDE.md" ] &&
        host_config+=(-v "${HOST_CLAUDE_DIR}/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro")
      [ -d "${HOST_CLAUDE_DIR}/agents" ] &&
        host_config+=(-v "${HOST_CLAUDE_DIR}/agents:/home/claude/.claude/agents:ro")
    fi

    echo "→ Creating persistent sandbox '${CONTAINER}'"
    # The boundary: non-root user (sudo on demand), only the project mounted in,
    # persistent ~/.claude volume, no Docker socket. PID 1 is a keep-alive; we
    # exec the actual work into it.
    docker run -d --name "${CONTAINER}" \
      --user claude \
      --hostname claudebox \
      -v "${CREDS_VOLUME}:/home/claude/.claude" \
      ${host_config[@]+"${host_config[@]}"} \
      -v "${PROJECT_ROOT}:/workspace" \
      -w /workspace \
      "${IMAGE}" sleep infinity >/dev/null
  fi
}

exec_in_container() {
  ensure_container
  docker exec -it -u claude -w /workspace "${CONTAINER}" "$@"
}

cmd="${1:-run}"
case "${cmd}" in
  build)
    build_image
    ;;
  login)
    # First launch with no credential triggers the OAuth device flow. Approve
    # the printed URL; the token is saved to the volume and reused after.
    echo "→ Logging in the sandbox for '${slug}' (separate from your host)."
    exec_in_container claude
    ;;
  shell)
    exec_in_container bash
    ;;
  stop)
    if docker stop "${CONTAINER}" >/dev/null 2>&1; then
      echo "✓ Sandbox stopped (state preserved). Next run restarts it."
    else
      echo "No running sandbox to stop."
    fi
    ;;
  reset)
    if docker rm -f "${CONTAINER}" >/dev/null 2>&1; then
      echo "✓ Sandbox '${CONTAINER}' removed; next run rebuilds it clean."
    else
      echo "No sandbox container to remove."
    fi
    ;;
  logout)
    # The login lives in the volume, which the container holds open — so remove
    # the container first, then the volume.
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    if docker volume rm "${CREDS_VOLUME}" >/dev/null 2>&1; then
      echo "✓ Logged out and sandbox removed."
    else
      echo "Sandbox removed; no login volume to forget."
    fi
    ;;
  clean)
    # Hashing the Dockerfile leaves one image tag per recipe version. Drop every
    # claudebox image except the current one. Images still backing a sandbox
    # container are in use and are skipped (reset that sandbox first to free it).
    removed=0
    for tag in $(docker image ls --format '{{.Repository}}:{{.Tag}}' \
                   | grep '^claudebox:' || true); do
      [ "${tag}" = "${IMAGE}" ] && continue
      docker image rm "${tag}" >/dev/null 2>&1 && removed=$((removed + 1)) || true
    done
    echo "✓ Removed ${removed} stale image(s); kept '${IMAGE}'."
    ;;
  run)
    shift || true
    # --dangerously-skip-permissions: auto-approve everything. Safe because the
    # container bounds the blast radius, not a prompt.
    exec_in_container claude --dangerously-skip-permissions "$@"
    ;;
  *)
    # Anything else is treated as a one-shot prompt for Claude.
    exec_in_container claude --dangerously-skip-permissions "$@"
    ;;
esac
