#!/bin/bash
# cmlops serve with a fake docker whose `compose up` starts a small HTTP server: the command runs
# with the API's URL, name and image once /v1/models answers, its exit code passes through, the
# server is removed on every exit, a server that dies is reported with its log, the run goes
# through the gpu gate, and a TERM to the real gate removes the server with or without a command.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need python3
need curl
scratch_dir
cmlops=$REPO_ROOT/bin/cmlops
mkdir -p "$SCRATCH/www/v1"
echo '{"data": [{"id": "m"}]}' >"$SCRATCH/www/v1/models"
port=$((20000 + RANDOM % 20000))

# The fake: `up` serves www/ on CMLOPS_SERVE_PORT unless FAKE_DEAD is set, `ps` lists it while it
# lives, `logs -f` follows until stopped, `down` stops it; every call is logged with the project and model.
cat >"$SCRATCH/docker" <<EOF
#!/bin/bash
args=" \$* "
echo "\$CMLOPS_SERVE_PROJECT \$CMLOPS_SERVE_MODEL \$*" >>"$SCRATCH/calls"
case \$args in
*" up "*)
  [ -n "\${FAKE_DEAD:-}" ] && exit 0
  python3 -m http.server -b 127.0.0.1 -d "$SCRATCH/www" "\$CMLOPS_SERVE_PORT" >/dev/null 2>&1 &
  echo \$! >"$SCRATCH/server.pid" ;;
*" ps "*) [ -s "$SCRATCH/server.pid" ] && kill -0 "\$(cat "$SCRATCH/server.pid")" 2>/dev/null && echo id ;;
*" logs -f "*) exec sleep 60 ;;
*" logs "*) echo "fake engine log" ;;
*" config "*) echo "engine/image:1@sha256:abc" ;;
*" down "*) [ -s "$SCRATCH/server.pid" ] && kill "\$(cat "$SCRATCH/server.pid")" 2>/dev/null; : >"$SCRATCH/server.pid" ;;
esac
EOF
# shellcheck disable=SC2016 # the fake gate's own $1 and $@
printf '#!/bin/bash\necho "gate $1" >>%q\nshift 2\nexec "$@"\n' "$SCRATCH/calls" >"$SCRATCH/gate"
chmod +x "$SCRATCH/docker" "$SCRATCH/gate"
fail() { die "cmlops serve: $1"; }
run() { # run [args...]: cmlops serve with the fakes; stdout only
  : >"$SCRATCH/calls"
  CMLOPS_SERVE_DOCKER=$SCRATCH/docker CMLOPS_SERVE_GATE=$SCRATCH/gate CMLOPS_SERVE_PORT=$port CMLOPS_SERVE_READY=20 \
    bash "$cmlops" serve "$@" 2>"$SCRATCH/err"
}

# shellcheck disable=SC2016 # expanded by the command, not here
out=$(run vllm /m/snap m -- sh -c 'echo "$CMLOPS_SERVE_URL $CMLOPS_SERVE_NAME $CMLOPS_SERVE_IMAGE"')
[[ $out == "http://127.0.0.1:$port/v1 m engine/image:1@sha256:abc" ]] || fail "the command saw '$out'"
grep -q '^gate gpu$' "$SCRATCH/calls" || fail "did not go through the gpu gate: $(cat "$SCRATCH/calls")"
grep -q 'tmp-serve-[0-9]* /m/snap .*--profile vllm up' "$SCRATCH/calls" || fail "up call: $(cat "$SCRATCH/calls")"
grep -q ' down ' "$SCRATCH/calls" || fail "the server was not removed"
! curl -sf "http://127.0.0.1:$port/v1/models" >/dev/null || fail "the server still answers after the run"

rc=0
run llama /m/f.gguf m -- sh -c 'exit 3' >/dev/null || rc=$?
[[ $rc == 3 ]] || fail "exit code $rc, not 3"
grep -q -- '--profile llama up' "$SCRATCH/calls" || fail "the llama profile was not used"
grep -q ' down ' "$SCRATCH/calls" || fail "the server was not removed after a failing command"

rc=0
FAKE_DEAD=1 run vllm /m/snap m -- echo never >"$SCRATCH/out" || rc=$?
[[ $rc == 1 ]] || fail "a dead server exited $rc, not 1"
[[ ! -s $SCRATCH/out ]] || fail "the command ran without a server"
grep -q 'fake engine log' "$SCRATCH/err" || fail "the engine log was not shown: $(cat "$SCRATCH/err")"
grep -q ' down ' "$SCRATCH/calls" || fail "a dead server was not removed"

printf '#!/bin/sh\nprintf "%%s\\n" "$*" >%q\nexit 1\n' "$SCRATCH/curl.args" >"$SCRATCH/curl"
chmod +x "$SCRATCH/curl"
rc=0
PATH="$SCRATCH:$PATH" FAKE_DEAD=1 run vllm /m/snap m -- echo never >/dev/null || rc=$?
[[ $rc == 1 ]] || fail "a failed bounded readiness probe exited $rc, not 1"
grep -q -- '--max-time 2' "$SCRATCH/curl.args" || fail "the readiness probe had no two-second timeout"

# TERM to the real gate reaches serve, which stops the command or the log follow and removes the
# server, instead of waiting for them.
term_case() { # term_case [-- CMD...]
  : >"$SCRATCH/calls"
  : >"$SCRATCH/err"
  CMLOPS_GATE_DIR=$SCRATCH/locks CMLOPS_GATE_HELPER=$SCRATCH/no-helper CMLOPS_SERVE_DOCKER=$SCRATCH/docker \
    CMLOPS_SERVE_PORT=$port CMLOPS_SERVE_READY=20 bash "$cmlops" serve vllm /m/snap m "$@" 2>"$SCRATCH/err" &
  local gate=$! server _
  for _ in $(seq 100); do
    grep -q 'cmlops serve: m on' "$SCRATCH/err" && break
    sleep 0.1
  done
  grep -q 'cmlops serve: m on' "$SCRATCH/err" || fail "the gated server never came up: $(cat "$SCRATCH/err")"
  server=$(cat "$SCRATCH/server.pid")
  kill -TERM "$gate"
  for _ in $(seq 100); do
    kill -0 "$gate" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$gate" 2>/dev/null; then
    kill -9 "$gate" 2>/dev/null
    kill "$server" 2>/dev/null
    fail "serve ${1:+with a command }did not stop within 10 s of a TERM to the gate"
  fi
  wait "$gate" 2>/dev/null || true
  grep -q ' down ' "$SCRATCH/calls" || fail "a TERM did not remove the server: $(cat "$SCRATCH/calls")"
  ! kill -0 "$server" 2>/dev/null || fail "the server lives on after a TERM"
}
term_case -- sleep 60
term_case

for bad in "bogus /m n -- true" "vllm /m" "vllm /m n true"; do
  rc=0
  # shellcheck disable=SC2086 # each case is a word list
  run $bad >/dev/null || rc=$?
  [[ $rc == 2 ]] || fail "'$bad' exited $rc, not 2"
done
echo 'OK: cmlops serve'
