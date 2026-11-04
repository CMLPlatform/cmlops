#!/bin/bash
# The tunnel connector without Cloudflare: `just setup` refuses a missing token file and a
# readable one, and the connector, run as the user from the root compose.yaml, reads a mode-600
# token file (a bogus token gets "not valid", not "permission denied"). Without a running Docker
# it skips. `just infra` covers infra/.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
have_docker || {
  echo "SKIP: the tunnel test needs a running Docker"
  exit 77
}
need just
scratch_dir
CMLOPS_UID=$(id -u) CMLOPS_GID=$(id -g)
export CMLOPS_UID CMLOPS_GID CMLOPS_MLFLOW_STORE=$SCRATCH/store CMLOPS_STATE=$SCRATCH/state
setup() { (cd "$REPO_ROOT" && just setup 2>&1); }
token=$CMLOPS_STATE/tunnel-token

out=$(setup) && die "tunnel: setup passed with no token file"
[[ $out == *"no tunnel token"* ]] || die "tunnel: setup without a token said '$out'"
printf bogus >"$token"
chmod 644 "$token"
out=$(setup) && die "tunnel: setup passed with a mode-644 token file"
[[ $out == *"mode 600"* ]] || die "tunnel: setup with a readable token said '$out'"
chmod 600 "$token"
setup >/dev/null || die "tunnel: setup refused a mode-600 token file"
out=$(compose_test -p "cmlops-test-$$" run --rm --quiet-pull cloudflared 2>&1) && die "tunnel: a bogus token connected"
[[ $out == *"token is not valid"* ]] || die "tunnel: the connector did not read the token file: ${out##*$'\n'}"
echo 'OK: tunnel'
