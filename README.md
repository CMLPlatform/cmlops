# cmlops

The ML stack of a single GPU node at CML: a GPU queue, model serving behind a standard
chat-completions HTTP API, one MLflow tracking server, and a Cloudflare tunnel behind Access.

| Path           | What it is                                                                       |
| -------------- | -------------------------------------------------------------------------------- |
| `bin/cmlops`   | The one command on PATH: `cmlops gate` and `cmlops serve`                        |
| `compose.yaml` | Every long-running service: it includes `mlflow/` and `tunnel/`                  |
| `mlflow/`      | The MLflow tracking server                                                       |
| `tunnel/`      | The Cloudflare tunnel connector                                                  |
| `infra/`       | OpenTofu: the tunnel, its DNS records and Access                                 |
| `serve/`       | The model servers `cmlops serve` starts per job, outside the root `compose.yaml` |
| `tests/`       | Shell tests, run by `just check`                                                 |
| `justfile`     | `just check` and the template's recipes; `just/local.just` has `setup`, `tofu`, `token` |
| `.env.example` | The settings Docker Compose and `just` read, to copy to `.env`                   |
| `.github/`     | CI (the compose workflow runs `just check`, the checks workflow the git hooks) and Dependabot |

## Deploying

The node runs the stack from a clone of this repo. Nothing else on the host needs to know it
exists beyond `bin/cmlops` on PATH and the tracking URI its users set.

The host needs Docker Engine with the Compose plugin 2.20 or later (for `include` and the
healthchecks' `start_interval`), `just`, OpenTofu (`just tofu` runs it on the host; only the
`just infra` check uses a container), `flock`, `curl` and bash 4 or later. `cmlops serve` also
needs the NVIDIA driver and the NVIDIA Container Toolkit.

1. `cp .env.example .env` and fill it in. Docker Compose and `just` both read it.
2. Set up the tunnel once (below), so `$CMLOPS_STATE/tunnel-token` exists.
3. `just setup` creates the MLflow store and the state dir as you, and checks the token file.
4. `docker compose up -d --wait`. The services come back on their own after a crash or a reboot,
   until `docker compose down`.
5. `ln -s "$PWD/bin/cmlops" ~/.local/bin/cmlops`, or into any other directory on PATH.

To run MLflow before the tunnel exists, skip step 2: `just setup` then creates the dirs, says
there is no token yet and exits 0, and `docker compose up -d --wait mlflow` starts MLflow alone.
Run `just setup` and the full `docker compose up -d --wait` once the token is there.

### Moving an existing setup

To take over a node that already runs MLflow and a tunnel from elsewhere:

1. Stop whatever holds the MLflow port, and any connector that runs for the same tunnel.
2. Point `CMLOPS_STATE` at the existing state dir, or move `terraform.tfstate`, `terraform.tfvars`
   and `tunnel-token` into it.
3. Run `just tofu init -reconfigure`, then `just tofu plan`. The plan must show no changes before
   any apply: an apply against empty state creates a second tunnel and DNS records that clash
   with the existing ones. If the old setup published other hostnames, list them in `services` in
   `terraform.tfvars` before the first plan, or the plan will delete them. A `terraform.tfvars`
   from before `team_name` existed needs that line added too.
4. Keep the existing store path in `CMLOPS_MLFLOW_STORE`.
5. Then `just setup` and `docker compose up -d --wait`.

Every service binds to 127.0.0.1 only; the tunnel with Access is the only way in from outside.
The service images in the compose files are pinned by tag and digest, and Dependabot bumps them;
the tool images in the justfile are pinned the same way and bumped by hand.

## Gate

`cmlops gate quiet|gpu|cpu [--wait SECONDS] -- CMD...` runs CMD under a lock shared by all of one user's jobs on the host:

- `quiet` is a timing run: it waits until no cpu or quiet job runs, and keeps new ones out.
- `cpu` is heavy work that is not timed. It runs beside other cpu and gpu jobs and waits while a
  quiet job runs.
- `gpu` is one GPU job at a time, beside any quiet or cpu job.

A gate inside a gate runs at once rather than waiting for itself, except quiet inside cpu, which
exits 2, and a gpu gate inside another gate, which still waits for the GPU lock. `--wait` gives up
with exit 75. While a quiet gate holds, an optional host helper can pin CPU clocks and move other
work off the timed CPUs: `CMLOPS_GATE_HELPER` names it, and `CMLOPS_GATE_CPUS` sets the timed CPUs.
The comment above `gate()` in `bin/cmlops` has the details.

## Serve

`cmlops serve vllm|llama MODEL NAME [-- CMD...]` serves a local model behind a chat-completions
API for the length of one command:

```sh
cmlops serve vllm ~/.cache/huggingface/hub/models--Qwen--Qwen3.5-9B/snapshots/<rev> qwen3.5-9b \
  -- python label.py   # label.py reads CMLOPS_SERVE_URL and CMLOPS_SERVE_NAME
CMLOPS_SERVE_MODELS=/srv/models CMLOPS_SERVE_ARGS='--n-cpu-moe 20' \
  cmlops serve llama /srv/models/lfm2.5-24b-a2b-q4_k_m.gguf lfm -- ...
```

MODEL is an absolute path under `CMLOPS_SERVE_HF` (default `~/.cache/huggingface`) or
`CMLOPS_SERVE_MODELS` (default `serve/models` in this clone, which git ignores): only those two
are mounted.

It goes through `cmlops gate gpu`, starts the engine from `serve/compose.yaml` under a throwaway
`tmp-serve-<pid>` project, waits until `/v1/models` answers, and runs CMD with `CMLOPS_SERVE_URL`,
`CMLOPS_SERVE_NAME` and `CMLOPS_SERVE_IMAGE` (the pinned image, for a run's record) set. The
server is removed on any exit, and CMD's exit code is serve's. Without CMD the server stays up
until serve is stopped; the URL is printed on stderr. No server runs all the time: an
idle one would hold the GPU's memory outside the gate. The comment above `serve()` lists the
settings.

## MLflow

One tracking server for every project on the node, on `127.0.0.1:${CMLOPS_MLFLOW_PORT:-5000}`.
A client talks HTTP and never opens the database itself, so a project's locked MLflow version
need not match the store's schema: only the server's version does.

The store is `$CMLOPS_MLFLOW_STORE`, mounted at `/mlflow`: `mlflow.db` and `artifacts/`. Back it
up from the host. Copy the database through SQLite's backup API, never with `cp` while the server
runs, which can copy a half-written file:

```sh
docker compose exec mlflow python -c "import sqlite3; sqlite3.connect('/mlflow/mlflow.db').backup(sqlite3.connect('/mlflow/mlflow.db.bak'))"
```

To upgrade MLflow, follow the comment at the top of `mlflow/compose.yaml`.

```sh
export MLFLOW_TRACKING_URI=http://127.0.0.1:5000
curl -s http://127.0.0.1:5000/health   # OK
```

Leave the artifact location to the server: a new experiment gets `mlflow-artifacts:/<id>`, and
the client uploads artifacts through the server. A local `artifact_location` would record a path
only one checkout has. `mlflow-skinny` is enough on the client side.

To delete runs for good, back up `mlflow.db` as above, then name the runs:

```sh
docker compose exec mlflow mlflow gc --backend-store-uri sqlite:////mlflow/mlflow.db \
  --artifacts-destination /mlflow/artifacts --run-ids <ids>
```

Without `--run-ids`, `gc` purges every soft-deleted run in the store.

## Telemetry

The node is a spoke of the CML monitoring hub ([CMLPlatform/monitoring](https://github.com/CMLPlatform/monitoring)).
Its files come from the hub's CML overlay, a Copier template with its own answers in
`.copier-answers.cml.yml`: `compose.telemetry.yml` (the Alloy agent), `compose.telemetry.gpu.yml`
(the GPU exporter), `deploy/alloy/config.alloy` and `scripts/run_scheduled.sh`. Never edit them
here; a monitoring release reaches them as

```sh
copier update --answers-file .copier-answers.cml.yml
```

To turn it on, add the lines from `telemetry.env.example` to `.env`, with the hub's ingest token
in `OTLP_AUTH_TOKEN`, and add the overlays to the compose files:

```sh
COMPOSE_FILE=compose.yaml:compose.telemetry.yml:compose.telemetry.gpu.yml
```

The hub operator runs `./bootstrap.sh cmlops prod` there first, which provisions the alert that
fires when the node goes silent.

## Tunnel

A Cloudflare tunnel publishes the node's web UIs behind Cloudflare Access, so a browser opens
them without `ssh -L`. `infra/` holds the tunnel, its ingress rules (ending in a 404), the DNS
records, one Access application per hostname and one shared policy for the allowed emails. Access
sends a one-time PIN to those addresses only; a session lasts 24 hours. Each ingress rule also
makes cloudflared check the Access token for its own application, so a request without one never
reaches the service. The connector in
`tunnel/compose.yaml` only dials out, and binds only a metrics port on 127.0.0.1:20241 for its
healthcheck.

`just tofu` runs OpenTofu with everything private in `$CMLOPS_STATE` (mode 700): the state, its
`.terraform` dir and `terraform.tfvars`. `just token` writes the connector's token there.

### First setup

1. In the Cloudflare dashboard (My Profile, API Tokens, Create Custom Token), make a token scoped
   to the account and the zone, with: Account, Cloudflare Tunnel, Edit; Account, Access: Apps and
   Policies, Edit; Zone, DNS, Edit.
2. Open the zone's Overview page: the API box in the right sidebar lists the Zone ID and the
   Account ID. The Zero Trust dashboard's settings show the team name (`team_name`), the first
   part of `<team_name>.cloudflareaccess.com`.
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

## Development

```sh
just check     # compose config, shell lint, secrets in history, hygiene, tofu fmt/validate/test and tests/
prek install   # the git hooks: file checks and linters on commit, the message on commit, `just check` on push
just hooks     # every git hook over the whole repo, as the checks workflow does
```

The linters and OpenTofu run in pinned containers, so `just check` needs Docker, and network
access for the images and for `tofu init` to fetch the provider. The hooks need prek. A test
that cannot run on the machine (no Docker, not Linux) prints SKIP and does not fail, except when
`CI` is set, as GitHub Actions does: there a skip fails the run.

## Licence

MIT. Per-file licensing is in `REUSE.toml`.
