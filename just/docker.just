# Lint images, pinned by digest so CI and a laptop run the same tools.
shellcheck := "koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d"
shfmt := "mvdan/shfmt:v3.12.0@sha256:307d265ffd25ce832899ae17c93ed5062fc3375c514bba8f52cbf52792735c4d"

# Run the stack in the background.
up:
    docker compose up -d --wait

# Stop it and remove the containers.
down:
    docker compose down

# Follow the service logs.
logs:
    docker compose logs -f

# The tracked shell scripts: *.sh, and any file whose first line is an sh, bash, dash or ksh shebang.
_shell-files:
    #!/usr/bin/env bash
    set -euo pipefail
    git ls-files -z | while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        # NOTE: a vendored file (.gitattributes) keeps its upstream format; upstream checks it.
        [ "$(git check-attr linguist-vendored -- "$f")" = "$f: linguist-vendored: set" ] && continue
        case $f in *.sh) printf '%s\0' "$f"; continue ;; esac
        if head -n1 "$f" | grep -qE '^#!.*/(env +)?(ba|da|k)?sh( |$)'; then printf '%s\0' "$f"; fi
    done

# Validate compose.yaml, then shellcheck and shfmt-check every shell script (needs Docker).
# The linters run from the pinned images above.
docker-check:
    #!/usr/bin/env bash
    set -euo pipefail
    # CI has no .env, and compose.yaml requires its settings: check it with the example ones.
    docker compose --env-file .env.example config -q
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < <("{{just_executable()}}" --quiet _shell-files)
    if [ ${#files[@]} -gt 0 ]; then
        run=(docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src:ro" -w /src)
        "${run[@]}" {{shellcheck}} "${files[@]}"
        "${run[@]}" {{shfmt}} -d -i 2 -ci "${files[@]}"
    fi

# Format every shell script with shfmt, with the flags docker-check uses (needs Docker).
docker-fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < <("{{just_executable()}}" --quiet _shell-files)
    if [ ${#files[@]} -gt 0 ]; then
        docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" -w /src {{shfmt}} -w -i 2 -ci "${files[@]}"
    fi
