#!/usr/bin/env bash
#
# Smoke test for claudebox.sh — exercises the sandbox lifecycle end to end and
# asserts the invariants that are easy to break when editing the script:
#
#   - the image builds and grants passwordless sudo
#   - a run creates a PERSISTENT container (not --rm), mounting the cwd
#   - host config is overlaid read-only, and settings.json is NOT imported
#   - sudo can write system paths, and writes survive a stop/start
#   - Claude state (.claude.json) lands in the persistent ~/.claude volume
#   - container create publishes --port, mounts --dir, and keeps installs
#   - container create refuses to recreate when the recipe changed
#   - container reset removes the box
#   - --help shows both claudebox's and Claude Code's help
#
# It works entirely in a temp directory with its own throwaway container/volume,
# so it never touches your real sandboxes. Requires Docker.
#
# This is a SMOKE test, not a full suite: it can't drive the interactive Claude
# or login flow (those need a real TTY), so it verifies everything around them.
#
#   test/smoke.sh

set -uo pipefail   # not -e: we want to run every assertion and tally failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDEBOX="${SCRIPT_DIR}/../claudebox.sh"

pass=0 fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
yes() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

# Negative checks against the container must not confuse "the condition holds"
# with "docker couldn't answer" (dead container / no daemon) — the latter would
# false-pass a `no`. So probe reachability first, then assert.
reachable() { docker exec -u claude "${CONTAINER}" true >/dev/null 2>&1; }
absent() {   # $1 = desc, $2 = path — passes only if the box answered AND path is missing
  if ! reachable; then bad "$1 (container unreachable)"; return; fi
  if docker exec -u claude "${CONTAINER}" test -e "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi
}
readonly_file() {   # $1 = desc, $2 = path — passes only if the file exists but rejects a write
  if ! reachable; then bad "$1 (container unreachable)"; return; fi
  if ! docker exec -u claude "${CONTAINER}" test -f "$2" >/dev/null 2>&1; then bad "$1 (file missing)"; return; fi
  if docker exec -u claude "${CONTAINER}" bash -c "echo x >> '$2'" >/dev/null 2>&1; then bad "$1 (writable)"; else ok "$1"; fi
}

# Isolated workspace + a fake host config dir, so we never touch real boxes.
WORK="$(mktemp -d)/claudebox-smoke"
HOSTCFG="$(mktemp -d)"
HOG="claudebox-smoke-hog"   # throwaway container used to occupy a port (rollback test)
mkdir -p "${WORK}" "${HOSTCFG}/agents"
printf '# smoke rules\n' > "${HOSTCFG}/CLAUDE.md"
printf '{"theme":"HOST-ONLY"}\n' > "${HOSTCFG}/settings.json"
export CLAUDE_CONFIG_DIR="${HOSTCFG}"   # claudebox reads the host config from here

cleanup() {
  trap - EXIT INT TERM   # disarm so a signal mid-cleanup can't re-enter
  ( cd "${WORK}" 2>/dev/null && "${CLAUDEBOX}" container reset >/dev/null 2>&1 )
  # Sweep any strays reset misses: the port hog and a leftover `-recreate` temp
  # (the name filter matches the smoke box and its temp by prefix).
  docker rm -f "${HOG}" $(docker ps -aq --filter name=claudebox-claudebox-smoke) >/dev/null 2>&1 || true
  # The drift check spoofs this throwaway image; drop it here too so a failure
  # before its inline removal can't leak it.
  docker image rm claudebox:faketag00000 >/dev/null 2>&1 || true
  docker volume rm $(docker volume ls -q --filter name=claudebox-claudebox-smoke) >/dev/null 2>&1 || true
  rm -rf "$(dirname "${WORK}")" "${HOSTCFG}"
}
# EXIT covers normal/failed/error exits; INT+TERM cover Ctrl-C and kill, which
# EXIT alone does not reliably catch.
trap cleanup EXIT INT TERM

cd "${WORK}"

# Preflight: every assertion shells out to docker. Without a working daemon
# (e.g. running this test INSIDE a sandbox), the negative checks would "pass"
# merely because the command errored — a false green. Bail loudly instead.
if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker is not available — run this on the host, not inside a sandbox." >&2
  exit 1
fi

echo "› build + sudo"
"${CLAUDEBOX}" container build >/dev/null 2>&1
IMG="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^claudebox:' | head -1)"
yes "image builds" test -n "${IMG}"
eq  "passwordless sudo resolves to root" root "$(docker run --rm --user claude "${IMG}" sudo whoami 2>/dev/null)"

echo "› create persistent sandbox"
# The interactive `docker exec -it` can't attach a TTY here, so this errors —
# but ensure_container runs first and creates the box, which is what we test.
"${CLAUDEBOX}" container shell </dev/null >/dev/null 2>&1 || true
CONTAINER="$(docker ps -aq --filter "name=claudebox-claudebox-smoke" | head -1)"
yes "container exists after a run (not --rm)" test -n "${CONTAINER}"
WS="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "${CONTAINER}" 2>/dev/null)"
case "${WS}" in *"${WORK}") ok "cwd is mounted at /workspace" ;; *) bad "cwd is mounted at /workspace (got '${WS}')" ;; esac

echo "› host config overlay"
yes "host CLAUDE.md is overlaid" docker exec -u claude "${CONTAINER}" test -f /home/claude/.claude/CLAUDE.md
readonly_file "host CLAUDE.md is read-only"   /home/claude/.claude/CLAUDE.md
absent        "settings.json is NOT imported" /home/claude/.claude/settings.json

echo "› sudo write + persistence across stop/start"
docker exec -u claude "${CONTAINER}" sudo touch /opt/claudebox-marker >/dev/null 2>&1
"${CLAUDEBOX}" container stop >/dev/null 2>&1
docker start "${CONTAINER}" >/dev/null 2>&1
yes "sudo-written /opt file survived stop/start" docker exec -u claude "${CONTAINER}" test -f /opt/claudebox-marker

echo "› Claude state persists in the volume"
docker exec -u claude "${CONTAINER}" claude config ls >/dev/null 2>&1 || true
yes ".claude.json written into ~/.claude volume" docker exec -u claude "${CONTAINER}" test -f /home/claude/.claude/.claude.json

echo "› container create: ports + dirs, keeping installs"
# An unusual high port, unlikely to collide with a real dev server (3000/8080/etc.)
# running in a sandbox on this same host while the test executes.
TEST_PORT=47921
EXTRA="$(dirname "${WORK}")/extralib"; mkdir -p "${EXTRA}"
docker exec -u claude "${CONTAINER}" sudo touch /opt/keep-marker >/dev/null 2>&1
"${CLAUDEBOX}" container create --port "${TEST_PORT}" --dir "${EXTRA}" >/dev/null 2>&1
CONTAINER="$(docker ps -aq --filter "name=claudebox-claudebox-smoke" | head -1)"   # same name, recreated
PB="$(docker container inspect -f '{{json .HostConfig.PortBindings}}' "${CONTAINER}" 2>/dev/null)"
case "${PB}" in *"${TEST_PORT}"*) ok "port ${TEST_PORT} published after create" ;; *) bad "port ${TEST_PORT} published (got '${PB}')" ;; esac
MNT="$(docker container inspect -f '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "${CONTAINER}" 2>/dev/null)"
case "${MNT}" in *extralib:/mnt/extralib*) ok "bare --dir mounts at /mnt/<name> (no host-path leak)" ;; *) bad "bare --dir mounts at /mnt/extralib (got '${MNT}')" ;; esac
no "create refuses mounting over a system path" "${CLAUDEBOX}" container create --dir "${EXTRA}:/lib"
yes "installs survived keep-recreate" docker exec -u claude "${CONTAINER}" test -f /opt/keep-marker
yes "recipe image survived keep-recreate" docker image inspect "${IMG}"

echo "› container create: rolls back on failure, keeping the old box"
# Occupy a second port with a throwaway container, then try to recreate onto it.
# The create must fail WITHOUT destroying the existing sandbox (the old bug:
# it removed the box before creating the replacement, losing it on any error).
TEST_PORT2=47922
docker run -d --name "${HOG}" -p "${TEST_PORT2}:${TEST_PORT2}" "${IMG}" sleep infinity >/dev/null 2>&1
OLD_ID="$(docker ps -q --filter "name=claudebox-claudebox-smoke" | head -1)"
no "create refuses when a published port is taken" "${CLAUDEBOX}" container create --port "${TEST_PORT2}"
NEW_ID="$(docker ps -q --filter "name=claudebox-claudebox-smoke" | head -1)"
eq  "old sandbox still running after failed recreate" "${OLD_ID}" "${NEW_ID}"
yes "installs intact after failed recreate" docker exec -u claude "${CONTAINER}" test -f /opt/keep-marker
docker rm -f "${HOG}" >/dev/null 2>&1 || true

echo "› container create: refuses when recipe changed"
# Spoof a different recipe hash via CLAUDEBOX_IMAGE; the box's label won't match,
# so a keep-recreate (which would freeze the old recipe) must refuse.
no "create refuses on recipe drift" env CLAUDEBOX_IMAGE=claudebox:faketag00000 "${CLAUDEBOX}" container create --port 9999
docker image rm claudebox:faketag00000 >/dev/null 2>&1 || true   # also swept by cleanup on early exit

echo "› reset"
"${CLAUDEBOX}" container reset >/dev/null 2>&1
no "container reset removed the container" docker container inspect "${CONTAINER}"

echo "› interface"
no "unknown container subcommand errors" "${CLAUDEBOX}" container bogus
HELP="$("${CLAUDEBOX}" --help 2>&1)"
case "${HELP}" in *"claudebox"*)   ok "--help shows claudebox section" ;; *) bad "--help shows claudebox section" ;; esac
case "${HELP}" in *"Claude Code"*) ok "--help shows Claude Code section" ;; *) bad "--help shows Claude Code section" ;; esac

echo
if [ "${fail}" -eq 0 ]; then
  printf '\033[32mPASS\033[0m — %d checks\n' "${pass}"
  exit 0
else
  printf '\033[31mFAIL\033[0m — %d passed, %d failed\n' "${pass}" "${fail}"
  exit 1
fi
