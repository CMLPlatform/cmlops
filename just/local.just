# cmlops's own recipes, imported by the justfile. Copier updates leave this file alone.

# .env (from .env.example) holds the paths and ids the recipes below share with Docker Compose.
set dotenv-load

gitleaks := "zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
tofu := "ghcr.io/opentofu/opentofu:1.12.3@sha256:a0766d12f07b43e66f2ed40d7a8babe97d581d20339c68ad0ab561737af9a5b3"

# The checks `just check` adds to the stack's: secrets in history, hygiene, the serve compose
# file, infra/ and the tests.
local-check: secrets hygiene compose-config infra test

# gitleaks over the whole git history (the betterleaks hook sees only staged changes). CI
# checks out the full history for it: a shallow clone would pass vacuously. The git dir is
# mounted at its own path too, so a worktree, whose .git file points there, is scanned as well.
secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    git_dir=$(git rev-parse --path-format=absolute --git-common-dir)
    docker run --rm --user "$(id -u):$(id -g)" -v "{{ justfile_directory() }}:/src:ro" -v "$git_dir:$git_dir:ro" -w /src {{ gitleaks }} git --no-banner /src

# Tracked files hold no home directory paths and no email addresses but GitHub noreply and the
# reserved example domains: a host's layout or a person's address does not belong in the repo.
hygiene:
    #!/usr/bin/env bash
    set -euo pipefail
    bad=0
    if git grep -nE '/(home|Users)/[A-Za-z0-9_.-]'; then bad=1; fi
    if git grep -nE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' |
      grep -vE '@(users\.noreply\.github\.com|example\.(org|com|net))'; then bad=1; fi
    [ "$bad" = 0 ] || { echo "error: home paths or email addresses in tracked files (above)" >&2; exit 1; }

# The per-job serve compose file parses with every profile (docker-check covers compose.yaml).
compose-config:
    CMLOPS_SERVE_MODEL=m CMLOPS_SERVE_NAME=n CMLOPS_SERVE_HF=/hf CMLOPS_SERVE_MODELS=/models docker compose -f serve/compose.yaml --profile vllm --profile llama config -q

# infra/ is formatted, valid, and its plan tests pass on a mocked provider. A copy inside the
# container keeps .terraform out of the clone; init needs the registry for the provider.
infra:
    docker run --rm --entrypoint sh -v {{ justfile_directory() }}/infra:/src:ro {{ tofu }} -c 'cp -R /src /work && cd /work && tofu fmt -check -recursive && tofu init -backend=false -input=false -lockfile=readonly >/dev/null && tofu validate -no-color && tofu test -no-color'

# The tests in tests/; one that cannot run here (no Docker, not Linux) says SKIP and exits 77.
# With CI set a skip fails the run, so CI cannot pass without running every test.
test:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0 ran=() skipped=() failed=()
    for t in tests/test-*.sh; do
      bash "$t"
      case $? in
        0) ran+=("$t") ;;
        77) skipped+=("$t") && [ -z "${CI:-}" ] || rc=1 ;;
        *) failed+=("$t") && rc=1 ;;
      esac
    done
    echo "tests: ${#ran[@]} passed, ${#skipped[@]} skipped${skipped[*]:+ (${skipped[*]})}, ${#failed[@]} failed${failed[*]:+ (${failed[*]})}"
    [ -z "${CI:-}" ] || [ ${#skipped[@]} -eq 0 ] || echo "error: CI is set, and a skipped test counts as a failure there" >&2
    exit "$rc"

# Once per host, and again after `just token`: the MLflow store and the state dir owned by this
# user, and a tunnel token only this user can read. Without a token only MLflow can start.
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${CMLOPS_MLFLOW_STORE:?set it in .env}" "${CMLOPS_STATE:?set it in .env}" "${CMLOPS_UID:?set it in .env}"
    [ "$CMLOPS_UID" = "$(id -u)" ] || { echo "error: CMLOPS_UID is $CMLOPS_UID in .env, but you are $(id -u)" >&2; exit 1; }
    # Docker would create a missing bind-mount source as root.
    mkdir -p "$CMLOPS_MLFLOW_STORE/artifacts"
    mkdir -p "$CMLOPS_STATE" && chmod 700 "$CMLOPS_STATE"
    token=$CMLOPS_STATE/tunnel-token
    if [ ! -e "$token" ]; then
      echo "no tunnel token at $token yet: only 'docker compose up -d --wait mlflow' will work until the tunnel is set up (README.md)."
      exit 0
    fi
    [ -s "$token" ] || { echo "error: $token is empty. Run 'just token' (README.md)." >&2; exit 1; }
    [ "$(stat -c %a "$token")" = 600 ] || { echo "error: $token must be mode 600: chmod 600 it." >&2; exit 1; }

# OpenTofu on infra/, with everything private in $CMLOPS_STATE: the state, .terraform and terraform.tfvars.
[positional-arguments]
tofu *args:
    #!/usr/bin/env bash
    set -euo pipefail
    state=${CMLOPS_STATE:?set it in .env}
    [ $# -gt 0 ] || { echo "usage: just tofu init|plan|apply|output|... [args]" >&2; exit 2; }
    mkdir -p "$state" && chmod 700 "$state"
    umask 077
    export TF_DATA_DIR=$state/.terraform
    sub=$1
    shift
    case $sub in
      init) extra=(-backend-config="path=$state/terraform.tfstate") ;;
      plan | apply | destroy | import | refresh | console) extra=(-var-file="$state/terraform.tfvars") ;;
      *) extra=() ;;
    esac
    exec tofu -chdir=infra "$sub" "${extra[@]}" "$@"

# Writes the connector's token to $CMLOPS_STATE/tunnel-token, mode 600.
token:
    #!/usr/bin/env bash
    set -euo pipefail
    token=${CMLOPS_STATE:?set it in .env}/tunnel-token
    umask 077
    just tofu output -raw tunnel_token >"$token.tmp"
    mv "$token.tmp" "$token"
    echo "wrote $token; restart the connector with 'docker compose up -d --force-recreate cloudflared' if it runs"
