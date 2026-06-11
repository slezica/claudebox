#!/usr/bin/env bash
#
# claudebox — run Claude Code in a Docker sandbox, with full autonomy inside it.
#
# A single self-contained script. Keep it anywhere (even on your PATH); it
# operates on your CURRENT DIRECTORY, so run it from your project root:
#
#   claudebox.sh                 Launch Claude on the current dir (auto-permissions)
#   claudebox.sh login           One-time login; credential persists in a volume
#   claudebox.sh build           Force-(re)build the sandbox image
#   claudebox.sh shell           Drop into a bash shell inside the sandbox
#   claudebox.sh logout          Forget this project's sandbox login
#   claudebox.sh clean           Remove stale image versions (keep the current)
#   claudebox.sh <prompt...>     Run Claude with a one-shot prompt
#
# Inside the container Claude runs with every action auto-approved; the Docker
# sandbox — not permission prompts — is the safety boundary.
#
# The image is shared across projects but tagged with the Dockerfile's hash, so
# editing the recipe auto-rebuilds and stale scripts never reuse a newer image.
# The login VOLUME is per-project, so each project gets its own session. Override
# either with env vars: CLAUDEBOX_IMAGE, CLAUDEBOX_VOLUME.

set -euo pipefail

# claudebox operates on the current working directory: that is the ONLY part of
# the host filesystem the container can see. Run it from your project root.
PROJECT_ROOT="$(pwd)"

# Slugify the project folder name for the per-project credential volume.
slug="$(basename "${PROJECT_ROOT}" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
[ -n "${slug}" ] || slug="project"

# Embedded Dockerfile. Read into a variable with a QUOTED heredoc delimiter so
# the shell does not expand ${USERNAME}/$PATH/$HOME — Docker must see them raw.
# Holding it in a var lets us both hash it and pipe it to `docker build`.
# (read -d '' returns non-zero at EOF, hence "|| true" under `set -e`.)
read -r -d '' DOCKERFILE <<'__DOCKERFILE__' || true
# Claude Code agent sandbox. The container is the safety boundary: inside it
# Claude runs with every action auto-approved, because what could go wrong is
# fenced off by Docker (non-root, dropped caps, no host FS) rather than by
# per-action prompts.
FROM node:22-slim

# Base tooling the agent needs to be useful on real projects.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep jq less \
  && rm -rf /var/lib/apt/lists/*

# Unprivileged user. The host filesystem is never mounted in; only the project
# is. So root-in-container would already be harmless — we drop it anyway.
ARG USERNAME=claude
RUN useradd --create-home --shell /bin/bash "${USERNAME}"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Install Claude Code via the native installer (no global npm). Binary lands in
# ~/.local/bin; config + credentials live in ~/.claude.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# Trust the bind-mounted repo. Without this, on hosts where the mount keeps its
# host UID (e.g. native Linux), git aborts with "dubious ownership" because the
# repo owner != the container user. Safe here: a disposable single-user sandbox.
RUN git config --global --add safe.directory /workspace

# Credentials + history live here; the script mounts a persistent named volume
# over it so the sandbox login survives runs and stays separate from the host.
RUN mkdir -p /home/${USERNAME}/.claude

WORKDIR /workspace
CMD ["claude", "--dangerously-skip-permissions"]
__DOCKERFILE__

# Tag the image with the Dockerfile's hash: identical recipes share one image,
# and any edit yields a new tag that rebuilds automatically instead of silently
# reusing a stale image.
dockerfile_hash() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(printf '%s' "${DOCKERFILE}" | shasum -a 256)"
  else
    out="$(printf '%s' "${DOCKERFILE}" | sha256sum)"
  fi
  printf '%s' "${out%% *}" | cut -c1-12
}

IMAGE="${CLAUDEBOX_IMAGE:-claudebox:$(dockerfile_hash)}"
CREDS_VOLUME="${CLAUDEBOX_VOLUME:-claudebox-${slug}-creds}"

build_image() {
  echo "→ Building image '${IMAGE}'"
  printf '%s' "${DOCKERFILE}" | docker build -t "${IMAGE}" -
}

ensure_image() {
  docker image inspect "${IMAGE}" >/dev/null 2>&1 || build_image
}

# Every run gets the same safety boundary. This is the whole point:
#   --user claude            : non-root inside the container
#   --cap-drop ALL           : strip every Linux capability
#   --security-opt no-new-...: a process can never gain more privileges
#   -v <cwd>:/workspace      : the current dir is the only host path mounted in
#   -v <vol>:~/.claude       : persistent, host-independent login
run_in_container() {
  ensure_image
  docker run --rm -it \
    --user claude \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --hostname claudebox \
    -v "${CREDS_VOLUME}:/home/claude/.claude" \
    -v "${PROJECT_ROOT}:/workspace" \
    -w /workspace \
    "${IMAGE}" "$@"
}

cmd="${1:-run}"
case "${cmd}" in
  build)
    build_image
    ;;
  login)
    # First launch with no credential triggers the OAuth device flow. Approve
    # the printed URL; the token is saved to the named volume and reused after.
    echo "→ Logging in the sandbox for '${slug}' (separate from your host)."
    run_in_container claude
    ;;
  shell)
    run_in_container bash
    ;;
  logout)
    if docker volume rm "${CREDS_VOLUME}" >/dev/null 2>&1; then
      echo "✓ Logged out — credential volume '${CREDS_VOLUME}' removed."
    else
      echo "Nothing to remove (volume '${CREDS_VOLUME}' does not exist)."
    fi
    ;;
  clean)
    # Hashing the Dockerfile leaves one tag per recipe version. Drop every
    # claudebox image except the one this script currently builds. Credential
    # volumes are left untouched (use `logout` for those).
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
    # --dangerously-skip-permissions: auto-approve everything. Safe ONLY because
    # the container is the boundary. Never use this flag on a bare host.
    run_in_container claude --dangerously-skip-permissions "$@"
    ;;
  *)
    # Anything else is treated as a one-shot prompt for Claude.
    run_in_container claude --dangerously-skip-permissions "$@"
    ;;
esac
