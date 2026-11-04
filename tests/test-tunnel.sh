#!/bin/bash
# The tunnel connector without Cloudflare: `just setup` without a token file creates the dirs and
# says only MLflow can start, it refuses a readable token file, and the connector, run as the user
# from the root compose.yaml, reads a mode-600 token file (a bogus token gets "not valid", not
# "permission denied"). Without a running Docker, or offline without the connector's image, it
# skips. `just infra` covers infra/.
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

out=$(setup) || die "tunnel: setup failed with no token file: $out"
[[ $out == *"no tunnel token"*"up -d --wait mlflow"* ]] || die "tunnel: setup without a token said '$out'"
[[ -d $CMLOPS_MLFLOW_STORE/artifacts && $(stat -c %a "$CMLOPS_STATE") == 700 ]] ||
  die "tunnel: setup without a token did not create the store and state dirs"
printf bogus >"$token"
chmod 644 "$token"
out=$(setup) && die "tunnel: setup passed with a mode-644 token file"
[[ $out == *"mode 600"* ]] || die "tunnel: setup with a readable token said '$out'"
chmod 600 "$token"
setup >/dev/null || die "tunnel: setup refused a mode-600 token file"
# The bogus token is refused locally, so only the image needs the network.
image=$(compose_test config --images cloudflared)
docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null 2>&1 || {
  echo "SKIP: the connector half of the tunnel test needs $image, and it could not be pulled (offline?)"
  exit 77
}
out=$(compose_test -p "cmlops-test-$$" run --rm cloudflared 2>&1) && die "tunnel: a bogus token connected"
[[ $out == *"token is not valid"* ]] || die "tunnel: the connector did not read the token file: ${out##*$'\n'}"
echo 'OK: tunnel'
