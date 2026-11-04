# cmlops

The ML stack of a single GPU node at CML: a GPU queue, model serving behind a standard
chat-completions HTTP API, one MLflow tracking server, a Cloudflare tunnel behind Access, and the host's telemetry as a
spoke of [CML monitoring](https://github.com/CMLPlatform/monitoring).

Status: scaffold. The components move in next; until then this repo holds only its checks.

## Deploying

The node runs the stack from a clone of this repo. Nothing else on the host needs to know it
exists beyond the tracking URI its users set.

## Checks

```sh
just check   # shellcheck, shfmt, actionlint, zizmor, gitleaks and REUSE lint, all in pinned containers
just hooks   # installs the git hooks (prek)
```

## Licence

MIT. Per-file licensing is in `REUSE.toml`.
