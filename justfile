# Lint images, pinned by digest so CI and a laptop run the same tools.
shellcheck := "koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d"
shfmt := "mvdan/shfmt:v3.12.0@sha256:307d265ffd25ce832899ae17c93ed5062fc3375c514bba8f52cbf52792735c4d"
actionlint := "rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667"
zizmor := "ghcr.io/zizmorcore/zizmor:1.16.0@sha256:a6460f1b6fe3dc08e588d314e73563bdd218ee30c995a4be5e9ee5bd300391ce"
gitleaks := "zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
reuse := "fsfe/reuse:5.0.2@sha256:000c3fc0c3e39e95b36fa9966d0104ae0496571b7de7b9f0c889a66438581bda"

run := "docker run --rm --user " + `id -u` + ":" + `id -g` + " -v " + justfile_directory() + ":/src:ro -w /src"

default:
    @just --list

# Everything CI runs.
check: lint

lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t sh < <(git ls-files -z | xargs -0 grep -lE '^#!.*(ba)?sh' 2>/dev/null || true)
    if [ ${#sh[@]} -gt 0 ]; then
      {{ run }} {{ shellcheck }} "${sh[@]}"
      {{ run }} {{ shfmt }} -d -i 2 -ci "${sh[@]}"
    fi
    {{ run }} {{ actionlint }}
    {{ run }} {{ zizmor }} --offline .github/workflows
    {{ run }} {{ gitleaks }} git --no-banner /src
    {{ run }} {{ reuse }} lint

# Staged diff only, for the pre-commit hook.
_gitleaks-staged:
    git diff --cached | docker run --rm -i {{ gitleaks }} stdin --no-banner

hooks:
    prek install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
