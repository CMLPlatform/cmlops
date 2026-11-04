#!/bin/bash
# cmlops gate's lock semantics with sleeping holders: quiet excludes cpu and quiet, gpu runs
# beside both, two gpu jobs exclude each other, --wait gives up with 75, nested
# gates do not wait for themselves, the lock goes with the gate, and quiet calls the
# bench helper on and off (also when the gate is stopped).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v flock >/dev/null || {
  echo "SKIP: cmlops gate needs flock (Linux)" >&2
  exit 77
}
(exec {fd}>/dev/null && exec {fd}>&-) 2>/dev/null || {
  echo "SKIP: cmlops gate needs bash 4.1+ ({fd} redirections), as on its Linux hosts" >&2
  exit 77
}
[[ -d /proc/self ]] || {
  echo "SKIP: cmlops gate reads /proc (Linux)" >&2
  exit 77
}
scratch_dir
cmlops=$REPO_ROOT/bin/cmlops
export CMLOPS_GATE_DIR=$SCRATCH/locks CMLOPS_GATE_HELPER=$SCRATCH/helper PATH=$SCRATCH/bin:$PATH
unset CMLOPS_GATE_QUIET CMLOPS_GATE_CPU CMLOPS_GATE_GPU
mkdir -p "$SCRATCH/bin"
# sudo -n <cmd...> runs the command; the helper logs its arguments.
cat >"$SCRATCH/bin/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && shift
exec "$@"
EOF
printf '#!/bin/bash\necho "$*" >>%q\necho helper-says-hi\n' "$SCRATCH/helper.log" >"$SCRATCH/helper"
chmod +x "$SCRATCH/bin/sudo" "$SCRATCH/helper"
fail() { die "cmlops gate: $1"; }

holder=
hold() { # hold <mode> [flags]: a gate held by a sleeping job, in the background
  rm -f "$SCRATCH/started"
  bash "$cmlops" gate "$@" -- bash -c "echo \$\$ >$SCRATCH/job; touch $SCRATCH/started; exec sleep 60" 2>/dev/null &
  holder=$!
  for _ in $(seq 100); do
    [[ -e $SCRATCH/started ]] && return
    sleep 0.05
  done
  fail "holder $* never started"
}
release() {
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}
trap 'release; rm -rf "$SCRATCH"' EXIT
try() { # try <mode> [flags]: the exit code of a gate that waits at most 1 s for `true`
  local rc=0
  bash "$cmlops" gate "$1" --wait 1 "${@:2}" -- true 2>/dev/null || rc=$?
  echo "$rc"
}

hold quiet
for m in cpu quiet; do [[ $(try $m) == 75 ]] || fail "$m ran beside quiet"; done
[[ $(try gpu) == 0 ]] || fail "gpu waited for quiet"
# A cpu job inside a gpu job still waits for quiet.
rc=0
bash "$cmlops" gate gpu --wait 1 -- bash "$cmlops" gate cpu --wait 1 -- true 2>/dev/null || rc=$?
[[ $rc == 75 ]] || fail "cpu inside gpu exited $rc beside quiet, not 75"
# A busy gate says why it waits; a free one says nothing.
err=$(bash "$cmlops" gate cpu --wait 1 -- true 2>&1 >/dev/null) || true
grep -q '^cmlops gate: waiting for quiet holders' <<<"$err" || fail "no waiting message: $err"
# An inherited CMLOPS_GATE_* naming a live ancestor that is not a gate does not skip the gate.
[[ $(CMLOPS_GATE_QUIET=$$ try cpu) == 75 ]] || fail "a stale CMLOPS_GATE_QUIET skipped the gate"
release
[[ -z $(bash "$cmlops" gate cpu -- true 2>&1) ]] || fail "a free gate printed something"

hold cpu
[[ $(try cpu) == 0 ]] || fail "two cpu jobs did not share"
[[ $(try gpu) == 0 ]] || fail "gpu did not share with cpu"
[[ $(try quiet) == 75 ]] || fail "quiet ran beside cpu"
t0=$SECONDS
try quiet >/dev/null
((SECONDS - t0 <= 3)) || fail "--wait 1 took $((SECONDS - t0)) s"
release

hold gpu
[[ $(try gpu) == 75 ]] || fail "two gpu jobs overlapped"
[[ $(try cpu) == 0 ]] || fail "cpu did not share with gpu"
[[ $(try quiet) == 0 ]] || fail "quiet waited for gpu"
release

# Killing the gate frees the lock although its job lives on: the job never holds the fd.
hold cpu
kill -9 "$holder"
wait "$holder" 2>/dev/null || true
[[ $(try quiet) == 0 ]] || fail "lock held after the gate died"
kill "$(cat "$SCRATCH/job")"

# Nested gates run at once instead of waiting for their parent; quiet inside cpu would deadlock.
out=$(bash "$cmlops" gate quiet --wait 1 -- bash "$cmlops" gate cpu --wait 1 -- bash "$cmlops" gate quiet --wait 1 -- echo nested 2>/dev/null) ||
  fail "nested gate inside quiet failed: $out"
[[ $out == nested ]] || fail "nested gate output: $out"
# The outer gate started by a relative path is still found from another working directory.
out=$(cd "$(dirname "$cmlops")" && bash "$(basename "$cmlops")" gate quiet --wait 1 -- bash -c "cd / && bash $cmlops gate cpu --wait 1 -- echo relative" 2>/dev/null) ||
  fail "a gate started by a relative path was not found: $out"
rc=0
bash "$cmlops" gate cpu --wait 1 -- bash "$cmlops" gate quiet --wait 1 -- true 2>/dev/null || rc=$?
[[ $rc == 2 ]] || fail "quiet inside cpu exited $rc, not 2"

# Exit code and stdin pass through.
rc=0
bash "$cmlops" gate cpu -- sh -c 'exit 3' || rc=$?
[[ $rc == 3 ]] || fail "exit code $rc, not 3"
[[ $(echo hi | bash "$cmlops" gate cpu -- cat) == hi ]] || fail "stdin did not reach the job"

# The bench helper: on with the CPUs and lock file around a quiet job, off after; never for cpu.
: >"$SCRATCH/helper.log"
[[ $(bash "$cmlops" gate quiet -- echo job 2>/dev/null) == job ]] || fail "the helper's output reached the job's stdout"
: >"$SCRATCH/helper.log"
CMLOPS_GATE_CPUS=16-23 bash "$cmlops" gate quiet -- true &
helper_pid=$!
wait "$helper_pid"
[[ $(cat "$SCRATCH/helper.log") == "bench on 16-23 $SCRATCH/locks/gate.lock $helper_pid"$'\n'"bench off" ]] ||
  fail "helper calls: $(cat "$SCRATCH/helper.log")"
# A different nested slot is applied only for that command, then the outer slot returns.
: >"$SCRATCH/helper.log"
CMLOPS_GATE_CPUS=16-23 bash "$cmlops" gate quiet -- bash -c '
  CMLOPS_GATE_CPUS=0-7 bash "$1" gate quiet -- sh -c "exit 3"
  rc=$?
  [[ $rc == 3 ]] || exit 1
  tail -1 "$2" >"$3"
' _ "$cmlops" "$SCRATCH/helper.log" "$SCRATCH/restored" 2>/dev/null
outer_on=$(head -1 "$SCRATCH/helper.log")
outer_pid=${outer_on##* }
[[ $(cat "$SCRATCH/helper.log") == "$outer_on"$'\n'"bench on 0-7 $SCRATCH/locks/gate.lock $outer_pid"$'\n'"$outer_on"$'\n'"bench off" ]] ||
  fail "nested slot did not switch and restore: $(cat "$SCRATCH/helper.log")"
[[ $(cat "$SCRATCH/restored") == "$outer_on" ]] || fail "outer slot restored too late"
# Keeping the same slot needs only the outer helper calls.
: >"$SCRATCH/helper.log"
CMLOPS_GATE_CPUS=16-23 bash "$cmlops" gate quiet -- bash "$cmlops" gate quiet -- true 2>/dev/null
[[ $(wc -l <"$SCRATCH/helper.log") == 2 ]] || fail "same slot called the helper again"
: >"$SCRATCH/helper.log"
bash "$cmlops" gate cpu -- true
[[ ! -s $SCRATCH/helper.log ]] || fail "cpu called the helper"
hold quiet
kill -TERM "$holder"
wait "$holder" 2>/dev/null || true
[[ $(tail -1 "$SCRATCH/helper.log") == "bench off" ]] || fail "a stopped quiet gate did not call bench off"
[[ $(try cpu) == 0 ]] || fail "lock held after a stopped quiet gate"

if bash "$cmlops" gate bogus -- true 2>/dev/null; then fail "accepted an unknown mode"; fi
if bash "$cmlops" gate cpu 2>/dev/null; then fail "ran without a command"; fi
echo 'OK: cmlops gate locks'
