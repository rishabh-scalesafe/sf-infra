# ScaleSafe Infrastructure

Cloud-agnostic Kubernetes platform for ScaleSafe:

| Layer | Tool | Where |
|---|---|---|
| Compute | Plain Ubuntu 24.04 VMs on **Azure / AWS / GCP** | `terraform/modules/{azure,aws,gcp}-k3s` |
| Kubernetes | **k3s** v1.36.5 (same bootstrap on every cloud) | `terraform/modules/k3s-cloudinit` |
| DNS / edge | **Cloudflare** (proxied, points at any cloud) | `terraform/modules/cloudflare-dns` |
| CI | **Tekton** Pipelines v1.17.1, Triggers v0.37.2, Dashboard v0.73.0 | `platform/tekton`, `tekton/` |
| Registry | **GHCR** (`ghcr.io/<org>/<app>`) | Tekton kaniko task |
| CD | **Argo CD** v3.5.7, app-of-apps GitOps | `platform/argocd`, `gitops/` |

All versions are pinned in [versions.env](versions.env), and every release was at least 2 weeks old when pinned.

## How it flows

```
 developer push ──► GitHub (app repo) ──webhook──► Tekton EventListener (hooks.<domain>)
                                                        │
             ┌──────────────────────────────────────────┘
             ▼
   PipelineRun: git-clone ─► run tests ─► kaniko build ─► push ghcr.io/<org>/<app>:<sha>
                                                            │
                                     gitops-update-image ◄──┘  (commits newTag to this repo)
                                                            │
   Argo CD watches gitops/ ──────────────────────────────────┘ ─► syncs Deployment ─► cluster
```

Tekton never deploys straight into the cluster. Every change goes through Git, which stays the single source of truth, so a rollback is just a `git revert`.

## Repo layout

```
terraform/
  modules/k3s-cloudinit   hardened cloud-init for k3s server/agent (shared by every cloud)
  modules/azure-k3s       VNet + NSG + VMs
  modules/aws-k3s         VPC + SG + EC2 (IMDSv2, encrypted gp3)
  modules/gcp-k3s         VPC + firewall + GCE (shielded VM)
  modules/cloudflare-dns  A records -> any cluster's ingress IPs
  envs/{azure,aws,gcp,cloudflare}   root configs (+ terraform.tfvars.example)
platform/
  namespaces/             ci + sample-app namespaces, PSA, quotas, NetworkPolicies
  tekton/                 Tekton releases (pinned URLs)
  argocd/                 Argo CD release + hardened config (read-only default RBAC)
tekton/                   CI definitions: tasks, pipeline, GitHub trigger, RBAC, PipelineRun pruner, smoke test
gitops/
  argocd/root.yaml        app-of-apps entry point
  argocd/projects/        AppProjects: platform (cluster-wide), apps (namespaced only)
  argocd/apps/            Argo CD Applications (Argo CD manages itself, Tekton, CI, apps)
  apps/sample-app/        template app: base + overlays/prod (GHCR) + overlays/quicktest
scripts/
  deploy.sh               terraform plan/apply/destroy + kubeconfig + platform, per cloud
  bootstrap-platform.sh   installs namespaces, Tekton, Argo CD, CI definitions
  create-ci-secrets.sh    GHCR/GitHub creds + webhook secret (from env vars, never on disk)
  configure.sh            replaces __GITHUB_ORG__ / __GITOPS_REPO_URL__ / __DOMAIN__
  smoke-test.sh           end-to-end checks (nodes, Tekton build, Argo CD sync, app)
  azure-quicktest.sh      2-VM test cluster with plain `az vm create`
  tunnel.sh               dev access over SSH only (API + services), stable on flaky links
  scalesafe/              ScaleSafe app: gen-manifests.py, secrets, build, set-version (rollback),
                          run-app-e2e, check-esign-orphans
gitops/apps/scalesafe/    ScaleSafe manifests (Postgres, Keycloak, 6 services, 2 web apps, site)
tests/e2e/                full-loop test: Gitea + registry stand in for GitHub + GHCR
docs/                     runbooks, security notes, test report
```

## Quick start (any cloud)

```bash
# 0. one-time: set your real values
scripts/configure.sh <github-org> https://github.com/<org>/<this-repo>.git scalesafe.co.in

# 1. infrastructure (pick a cloud; the steps are identical)
cp terraform/envs/azure/terraform.tfvars.example terraform/envs/azure/terraform.tfvars   # edit it
scripts/deploy.sh azure plan
scripts/deploy.sh azure apply
scripts/deploy.sh azure kubeconfig
export KUBECONFIG=$PWD/.local/azure/kubeconfig

# 2. platform
scripts/deploy.sh azure platform             # Tekton + Argo CD + CI definitions
GITHUB_USER=... GITHUB_TOKEN=... GITOPS_REPO_URL=... scripts/create-ci-secrets.sh

# 3. hand over to GitOps (after pushing this repo to GitHub)
kubectl apply -f gitops/argocd/root.yaml

# 4. point Cloudflare at the cluster
cp terraform/envs/cloudflare/terraform.tfvars.example terraform/envs/cloudflare/terraform.tfvars  # origin_ips = ingress_ips
export CLOUDFLARE_API_TOKEN=...
scripts/deploy.sh cloudflare apply
```

To move clouds, run the same steps with `aws` or `gcp`, then change `origin_ips` in the Cloudflare tfvars and apply it again. Nothing in `platform/`, `tekton/` or `gitops/` is tied to a specific cloud.

## Adding a new application

1. App repo: put a `Dockerfile` at the repo root.
2. In this repo, copy `gitops/apps/sample-app` to `gitops/apps/<repo-name>`. Set `newName: ghcr.io/<org>/<repo-name>` in `overlays/prod/kustomization.yaml`.
3. Copy `gitops/argocd/apps/sample-app.yaml` to `<repo-name>.yaml`, and add the namespace in `platform/namespaces/`.
4. In the GitHub app repo, add a webhook: `https://hooks.<domain>/`, content type `application/json`, the secret printed by `create-ci-secrets.sh`, and the push event only.

## Docs

- [docs/MORNING-REPORT.md](docs/MORNING-REPORT.md): what was built and tested overnight, with results.
- [docs/SECURITY.md](docs/SECURITY.md): security controls and the hardening backlog.
- [docs/RUNBOOK.md](docs/RUNBOOK.md): day-2 operations (access, rotate, upgrade, teardown).
- [docs/STATE.md](docs/STATE.md): where Terraform state and secrets live.
