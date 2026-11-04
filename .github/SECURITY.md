# Security

<!-- The advisories link below works only once Settings > Code security >
     Private vulnerability reporting is on. `just repo-settings` turns it on. -->

## Report a vulnerability

Report it privately, through
[a GitHub security advisory](https://github.com/CMLPlatform/cmlops/security/advisories/new).
Don't open a public issue or pull request for it:
anyone can read those before there is a fix.

Please include:

- What the problem is and where it is: a file, a function or a dependency.
- Steps to reproduce it, or a proof of concept.
- The impact you expect, and the version you saw it in.

I acknowledge a report within 14 days, then tell you whether I can reproduce it and when I
expect a fix.

## Fixes and disclosure

A fix lands on `main`, which is what a deployment runs. When it is out, I publish the GitHub security advisory for
it, with a CVE where one applies, and credit you unless you'd rather not be named. The
CHANGELOG entry for that release links the advisory.

## Scope

cmlops is the deployment of one GPU node: Compose files, shell scripts and OpenTofu. It
publishes no package. The services it runs are upstream images, and MLflow has no login of
its own, so the tunnel's Access policy is its only gate.

In scope:

- The code in this repository: `bin/cmlops`, the Compose files, `infra/` and the tests.
- Anything here that would expose a service past Access, or a token or state file.
- The CI and release workflows in `.github/workflows`.
- The pinned images and the OpenTofu provider, when the problem affects this deployment.

Out of scope:

- A problem in MLflow, cloudflared, vLLM or llama.cpp themselves. Report it upstream.
- Cloudflare's own Access and tunnel service.
