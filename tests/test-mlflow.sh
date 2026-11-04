#!/bin/bash
# The MLflow service from the root compose.yaml, as its own project on a scratch store and a free
# port: `just setup` creates the store, the container turns healthy, /health answers on the
# published port, only the configured public host gets past the Host-header check, a run with an
# artifact logged over HTTP reads back through the server, the artifact lands in the store owned
# by the user, the restart policy is unless-stopped, and down removes it. Without a running
# Docker it skips.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
have_docker || {
  echo "SKIP: the MLflow test needs a running Docker"
  exit 77
}
need curl
need just
scratch_dir
CMLOPS_UID=$(id -u) CMLOPS_GID=$(id -g)
export CMLOPS_UID CMLOPS_GID CMLOPS_MLFLOW_STORE=$SCRATCH/store CMLOPS_STATE=$SCRATCH/state
export CMLOPS_MLFLOW_HOST=mlflow.example.org CMLOPS_MLFLOW_PORT=$((20000 + RANDOM % 20000))
project=cmlops-test-$$
dc=(compose_test -p "$project")
trap '"${dc[@]}" down >/dev/null 2>&1 || true; rm -rf "$SCRATCH"' EXIT
fail() { die "mlflow: $1 (log: $("${dc[@]}" logs --tail 5 mlflow 2>&1))"; }
url=http://127.0.0.1:$CMLOPS_MLFLOW_PORT

# setup also wants the tunnel's token; any mode-600 file will do here.
mkdir -p "$CMLOPS_STATE"
(umask 077 && printf bogus >"$CMLOPS_STATE/tunnel-token")
(cd "$REPO_ROOT" && just setup) || fail "just setup failed"
"${dc[@]}" up -d --wait --quiet-pull mlflow >"$SCRATCH/up.log" 2>&1 || fail "up failed: $(tail -3 "$SCRATCH/up.log")"
[[ $(curl -s --max-time 5 "$url/health") == OK ]] || fail "/health did not answer OK"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $1" "$url/api/2.0/mlflow/experiments/search?max_results=1"; }
[[ $(code "$CMLOPS_MLFLOW_HOST") == 200 ]] || fail "the public host was refused"
[[ $(code other.example.com) != 200 ]] || fail "another host got past the Host-header check"

# The client runs in the server's image and talks HTTP to the server, as any project would.
out=$("${dc[@]}" exec -T -e MLFLOW_TRACKING_URI=http://127.0.0.1:5000 mlflow python -c '
import mlflow, pathlib
exp = mlflow.create_experiment("scratch")
src = pathlib.Path("/tmp/a.txt")
src.write_text("round trip")
with mlflow.start_run(experiment_id=exp) as run:
    mlflow.log_param("p", 1)
    mlflow.log_artifact(str(src))
got = pathlib.Path(mlflow.artifacts.download_artifacts(run_id=run.info.run_id, artifact_path="a.txt"))
print(mlflow.get_experiment(exp).artifact_location, mlflow.get_run(run.info.run_id).data.params["p"], got.read_text())
' 2>&1) || fail "logging a run failed: $out"
out=${out##*$'\n'} # MLflow prints run links first
[[ $out == "mlflow-artifacts:/1 1 round trip" ]] || fail "the run read back as '$out'"
art=$(echo "$SCRATCH"/store/artifacts/1/*/artifacts/a.txt)
[[ $(cat "$art") == "round trip" ]] || fail "the artifact is not in the store"
[[ -s $SCRATCH/store/mlflow.db ]] || fail "no mlflow.db in the store"
[[ $(stat -c %u "$SCRATCH/store/mlflow.db") == "$(id -u)" && $(stat -c %u "$art") == "$(id -u)" ]] ||
  fail "the store is not owned by $(id -un)"
[[ $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$project-mlflow-1") == unless-stopped ]] ||
  fail "the restart policy is not unless-stopped"

"${dc[@]}" down >/dev/null 2>&1 || fail "down failed"
! curl -s --max-time 2 "$url/health" >/dev/null || fail "the server still answers after down"
echo 'OK: mlflow'
