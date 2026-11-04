# cmlops

The ML stack of a single GPU node at CML: a GPU queue, model serving behind a standard
chat-completions HTTP API, one MLflow tracking server, a Cloudflare tunnel behind Access, and the host's telemetry as a
spoke of [CML monitoring](https://github.com/CMLPlatform/monitoring).

| Path           | What it is                                                                       |
| -------------- | -------------------------------------------------------------------------------- |
| `bin/cmlops`   | The one command on PATH: `cmlops gate` and `cmlops serve`                        |
| `compose.yaml` | Every long-running service: it includes `mlflow/` and `tunnel/`                  |
| `mlflow/`      | The MLflow tracking server                                                       |
| `tunnel/`      | The Cloudflare tunnel connector                                                  |
| `infra/`       | OpenTofu: the tunnel, its DNS records and Access                                 |
| `serve/`       | The model servers `cmlops serve` starts per job, outside the root `compose.yaml` |
| `tests/`       | Shell tests, run by `just check`                                                 |

## Deploying

The node runs the stack from a clone of this repo. Nothing else on the host needs to know it
exists beyond `bin/cmlops` on PATH and the tracking URI its users set.

1. `cp .env.example .env` and fill it in. Docker Compose and `just` both read it.
2. Set up the tunnel once (below), so `$CMLOPS_STATE/tunnel-token` exists.
3. `just setup` creates the MLflow store and the state dir as you, and checks the token file.
4. `docker compose up -d --wait`. The services come back on their own after a crash or a reboot,
   until `docker compose down`.
5. `ln -s "$PWD/bin/cmlops" ~/.local/bin/cmlops`, or into any other directory on PATH.

Every service binds to 127.0.0.1 only; the tunnel with Access is the only way in from outside.
Images are pinned by tag and digest, and Dependabot bumps them.

## Gate

`cmlops gate quiet|gpu|cpu [--wait SECONDS] -- CMD...` runs CMD under a host-wide lock:

- `quiet` is a timing run: it waits until no cpu or quiet job runs, and keeps new ones out.
- `cpu` is heavy work that is not timed. It runs beside other cpu and gpu jobs and waits while a
  quiet job runs.
- `gpu` is one GPU job at a time, beside any quiet or cpu job.

A gate inside a gate runs at once rather than waiting for itself. `--wait` gives up with exit 75.
While a quiet gate holds, an optional host helper can pin CPU clocks and move other work off the
timed CPUs. The comment above `gate()` in `bin/cmlops` has the details and the settings.

## Serve

`cmlops serve vllm|llama MODEL NAME -- CMD...` serves a local model behind a chat-completions API
for the length of one command:

```sh
cmlops serve vllm ~/.cache/huggingface/hub/models--Qwen--Qwen3.5-9B/snapshots/<rev> qwen3.5-9b \
  -- python label.py   # label.py reads CMLOPS_SERVE_URL and CMLOPS_SERVE_NAME
CMLOPS_SERVE_ARGS='--n-cpu-moe 20' cmlops serve llama /models/lfm2.5-24b-a2b-q4_k_m.gguf lfm -- ...
```

It goes through `cmlops gate gpu`, starts the engine from `serve/compose.yaml` under a throwaway
`tmp-serve-<pid>` project, waits until `/v1/models` answers, and runs CMD with `CMLOPS_SERVE_URL`,
`CMLOPS_SERVE_NAME` and `CMLOPS_SERVE_IMAGE` (the pinned image, for a run's record) set. The
server is removed on any exit, and CMD's exit code is serve's. No server runs all the time: an
idle one would hold the GPU's memory outside the gate. The comment above `serve()` lists the
settings.

## MLflow

One tracking server for every project on the node, on `127.0.0.1:${CMLOPS_MLFLOW_PORT:-5000}`.
A client talks HTTP and never opens the database itself, so a project's locked MLflow version
need not match the store's schema: only the server's version does.

The store is `$CMLOPS_MLFLOW_STORE`, mounted at `/mlflow`: `mlflow.db` and `artifacts/`. Back it
up from the host. To upgrade MLflow, follow the comment at the top of `mlflow/compose.yaml`.

```sh
export MLFLOW_TRACKING_URI=http://127.0.0.1:5000
curl -s http://127.0.0.1:5000/health   # OK
```

Leave the artifact location to the server: a new experiment gets `mlflow-artifacts:/<id>`, and
the client uploads artifacts through the server. A local `artifact_location` would record a path
only one checkout has. `mlflow-skinny` is enough on the client side.

To delete runs for good, always name them: `mlflow gc --backend-store-uri ... --run-ids <ids>`.
Without `--run-ids`, `gc` purges every soft-deleted run in the store. Back up `mlflow.db` first.

## Tunnel

A Cloudflare tunnel publishes the node's web UIs behind Cloudflare Access, so a browser opens
them without `ssh -L`. `infra/` holds the tunnel, its ingress rules (ending in a 404), the DNS
records, one Access application per hostname and one shared policy for the allowed emails. Access
sends a one-time PIN to those addresses only; a session lasts 24 hours. The connector in
`tunnel/compose.yaml` only dials out and binds no port.

`just tofu` runs OpenTofu with everything private in `$CMLOPS_STATE` (mode 700): the state, its
`.terraform` dir and `terraform.tfvars`. `just token` writes the connector's token there.

### First setup

1. In the Cloudflare dashboard (My Profile, API Tokens, Create Custom Token), make a token scoped
   to the account and the zone, with: Account, Cloudflare Tunnel, Edit; Account, Access: Apps and
   Policies, Edit; Zone, DNS, Edit.
2. Open the zone's Overview page: the API box in the right sidebar lists the Zone ID and the
   Account ID.
3. Fill in the variables (`set -a; . ./.env; set +a` puts `CMLOPS_STATE` in the shell):

   ```sh
   mkdir -p -m 700 "$CMLOPS_STATE"
   cp infra/terraform.tfvars.example "$CMLOPS_STATE/terraform.tfvars"
   $EDITOR "$CMLOPS_STATE/terraform.tfvars"
   ```

4. Apply, with the API token in the environment for this shell only, then write the connector
   token:

   ```sh
   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
   just tofu init
   just tofu apply
   just token
   ```

Access sends the PIN only if the account has the One-time PIN login method (Zero Trust, Settings,
Authentication).

### Adding a hostname

Add `subdomain = "http://127.0.0.1:<port>"` to `services` in `terraform.tfvars` (the default is in
`infra/variables.tf`), then `just tofu apply`. The ingress rule, the DNS record and the Access
application all follow from that map, and the tests fail if a hostname would lack Access. The
connector picks up the new route on its own, since the tunnel is managed from Cloudflare.

### Threats

- MLflow has no login. Access is its only gate, so every hostname gets an Access application, and
  `tofu test` checks that.
- Keep the services bound to 127.0.0.1. Then the local network cannot reach them directly, and
  the only way in from outside is through Access. `services` refuses anything else.
- The tunnel token lets whoever holds it run a connector for this tunnel, and so serve its
  hostnames. It lives only in `$CMLOPS_STATE/tunnel-token` (mode 600, checked by `just setup`) and
  in the state file next to it. To rotate it, replace the tunnel and its token:

  ```sh
  just tofu apply -replace=cloudflare_zero_trust_tunnel_cloudflared.node
  just token
  docker compose up -d --force-recreate cloudflared
  ```

  The new tunnel gets a new ID, and the DNS records follow it in the same apply.

## Checks

```sh
just check   # lint, hygiene, compose config, tofu fmt/validate/test and tests/
just hooks   # installs the git hooks (prek)
```

The linters and OpenTofu run in pinned containers. A test that cannot run on the machine (no
Docker, not Linux) prints SKIP and does not fail.

## Licence

MIT. Per-file licensing is in `REUSE.toml`.
