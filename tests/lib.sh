# shellcheck shell=bash
# Helpers the tests share. Sourced, never executed. A test exits 77 when it skips.

# The checkout these tests live in, always: an inherited REPO_ROOT would point them at another tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# scratch_dir: a fresh temp dir in $SCRATCH, removed on exit. Call it directly, never in $(...):
# the trap would fire as that subshell exits. A test with more to clean up sets its own EXIT
# trap afterwards, which replaces this one.
scratch_dir() {
  SCRATCH=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cmlops-test.XXXXXX")" && pwd -P)
  trap 'rm -rf "$SCRATCH"' EXIT
}

# The root compose project on .env.example, so a deployed .env never reaches a test; the caller
# exports the CMLOPS_* values it needs, which win over the file.
compose_test() {
  docker compose --project-directory "$REPO_ROOT" --env-file "$REPO_ROOT/.env.example" "$@"
}
