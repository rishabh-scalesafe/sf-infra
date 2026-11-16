# Morning report: ScaleSafe infrastructure (overnight build, 16 Nov 2026)

**Status: built and tested end to end on a live Azure cluster. Nothing was pushed to GitHub.**

## Final check, 05:43–06:10 IST

```
$ kubectl get nodes
sfqt-agent-0    Ready    <none>          4h55m   v1.36.5+k3s1
sfqt-server-0   Ready    control-plane   4h58m   v1.36.5+k3s1

$ kubectl -n argocd get applications
argocd  ci-pipelines  platform-namespaces  root  sample-app  scalesafe  smoke-guestbook  tekton
-> all 8 Synced + Healthy

argocd pods: 7 Running    tekton-pipelines pods: 7 Running    unhealthy pods cluster-wide: 0
scalesafe: 10/10 deployments 1/1 (6 services, keycloak, web-app, web-admin, site) at 7dc0462

$ scripts/smoke-test.sh   (re-run this morning)
PASS  all nodes Ready
PASS  kube-system pods healthy
PASS  tekton-pipelines pods healthy
PASS  argocd pods healthy
PASS  tekton pipeline registered
PASS  eventlistener ready
PASS  tekton pipeline clone->test->kaniko build
PASS  argo cd git sync -> Healthy app
PASS  sample-app (restricted PSA, netpol) serves HTTP 200
PASS  k3s secrets encryption enabled        (Encryption Status: Enabled)
PASS  ssh password auth disabled            (passwordauthentication no)
PASS  apiserver audit log written           (rotated at 100 MB x 10)
RESULT: 12 passed, 0 failed
```

The three node checks were re-run by hand. My first command used a key path with a space in it (`sf infra`), so SSH couldn't find the key; that was my mistake in the command, not a problem on the node.

**A real bug the morning check found, now fixed: CI would have stopped after about 20 builds.** Each PipelineRun creates a PVC for its workspace, and Tekton deletes that PVC only when the PipelineRun itself is deleted. Nothing was deleting old runs, so after 20 builds the `ci` namespace hit its `persistentvolumeclaims: 20` quota, and the morning smoke build sat in `PipelineRunPending` ("exceeded quota: ci-quota"). In production, CI would have quietly stopped about 20 pushes in.
- Fix: [tekton/pruner.yaml](../tekton/pruner.yaml), a CronJob that runs every 30 minutes and keeps the newest 10 finished PipelineRuns. It uses a least-privilege Role (get/list/delete pipelineruns in `ci` only), runs non-root with a read-only root filesystem, and never touches running or pending runs.
- It was shipped through GitOps (commits 68c0f39 and 80e5a9c, synced by Argo CD), not with kubectl apply.
- Verified: after the fix the smoke build ran, and a manual pruner run reported `finished=10 pruned=0 keep=10`. The `ci` namespace now has 10 PVCs against a quota of 20.

## Second request (02:17): build and deploy all of ScaleSafe, downgrade it, find the issue, fix it, make a deck

**Done.** Full detail is in [SCALESAFE-DEPLOY-REPORT.md](SCALESAFE-DEPLOY-REPORT.md).
- **Built and deployed.** Every ScaleSafe image went through this platform's own Tekton → GitOps → Argo CD pipeline: 6 services, portal, admin console and the corporate site. That's 9 images in 8.5 minutes. The manifests were written fresh; nothing was copied from `scalesafe-platform/deploy` or `infra`.
- **Tested.** ScaleSafe's own e2e suites pass on the cluster: **47/47** client onboarding and **125/125** investor onboarding.
- **Downgraded** from 7dc0462 to 273b1a2. Everything showed Healthy, but **old esign-service code wrote a signing request without the document text**, which the newer code needs to show the investor what they sign. Flyway only warned about it.
- **Fixed.**
  - A Flyway downgrade guard plus a zero-downtime rollout strategy. With the guard, the old esign version is blocked at startup and the current one keeps serving; this was proven by repeating the downgrade.
  - A detection script, `check-esign-orphans.sh`. It found exactly the one affected request (ACME-2026-000006). Deciding how to re-issue it is an **application decision for you**; I didn't touch app code.
- **Rollback lesson.** Rolling back by re-pinning image tags (`set-version.sh`) takes **80 seconds** and gives back the exact same images. Rebuilding old commits takes about 10 minutes and doesn't.
- **Deck** (12 slides): https://claude.ai/artifact/DYygBhKqTMxktKH94boauB. It's private; share it from the page's Share menu.
- **Final state:** ScaleSafe 7dc0462 running and healthy in namespace `scalesafe` on the test cluster.

Access while the tunnel runs (`scripts/tunnel.sh`):

| What | URL |
|---|---|
| Portal | http://localhost:5173 |
| Admin console | http://localhost:5174 |
| Keycloak | http://localhost:8180 |
| Argo CD | http://localhost:18080 |
| Tekton dashboard | http://localhost:19097 |

The tunnel also installed a node-side unit, `sf-forwards`, on the server. Remove it with `scripts/tunnel.sh stop-node`.

---

## What you have

| Piece | Status | Tested how |
|---|---|---|
| Terraform: Azure / AWS / GCP k3s clusters + Cloudflare DNS | Done | `terraform validate` passes for all 4. The Azure path was proven live with the same cloud-init. |
| Shared hardened VM bootstrap (k3s v1.36.5) | Done | Ran on 2 Azure VMs; both nodes Ready in about 5 minutes |
| Tekton CI: clone → test → kaniko build → push to GHCR → GitOps bump | Done | Ran live (see e2e below) |
| GitHub webhook trigger (HMAC-verified, main branch only) | Done | Bad signature rejected; good signature started a pipeline |
| Argo CD app-of-apps (Argo CD manages itself, Tekton, CI and apps) | Done | All 6 apps Synced and Healthy |
| Security baseline (PSA, NetworkPolicies, secrets encryption, audit log, SSH hardening, read-only RBAC) | Done | Checked live by the smoke test |
| Docs: README, RUNBOOK, SECURITY, STATE | Done | |

## Test results (real runs)

**Smoke test** (`scripts/smoke-test.sh`): **12 passed, 0 failed**

```
PASS  all nodes Ready
PASS  kube-system pods healthy
PASS  tekton-pipelines pods healthy
PASS  argocd pods healthy
PASS  tekton pipeline registered
PASS  eventlistener ready
PASS  tekton pipeline clone->test->kaniko build
PASS  argo cd git sync -> Healthy app
PASS  sample-app (restricted PSA, netpol) serves HTTP 200
PASS  k3s secrets encryption enabled
PASS  ssh password auth disabled
PASS  apiserver audit log written
RESULT: 12 passed, 0 failed
```

**Full GitOps loop** (`tests/e2e/run-e2e.sh`): **9 passed, 0 failed**

GitHub and GHCR were not used, because nothing could be pushed to them. A throwaway Gitea and container registry inside the test cluster stood in for them. Everything else is the real pipeline, triggers and Argo CD config from this repo.

```
PASS  push GitOps repo to Gitea
PASS  push app repo to Gitea
PASS  Argo CD app-of-apps: all 6 apps Synced
PASS  webhook accepted                                   (GitHub-format, HMAC-signed)
PASS  Tekton: clone -> test -> build -> push -> gitops bump
PASS  image sample-app:20eb2fc in registry
PASS  GitOps repo has Tekton bump commit                 (newTag: "20eb2fc")
PASS  Argo CD rolled out new image and app is Healthy
PASS  new build serving traffic                          ("ScaleSafe sample-app - deployed by Tekton + Argo CD")
E2E RESULT: 9 passed, 0 failed
```

Webhook security check: a request with a wrong signature was rejected by the interceptor (`payload signature check failed`), and no pipeline ran.

## The Azure test cluster (still running)

| | |
|---|---|
| Resource group | `sf-infra-qt-rg` (Central India). It's separate from your existing `creative` resource groups, which were not touched. |
| VMs | `sfqt-server-0` (20.219.131.118), `sfqt-agent-0` (20.198.89.69). Both Standard_B2as_v2 (2 vCPU / 8 GB). |
| Access | SSH, 6443 and 80/443 are open **only to your IP at build time** |
| Cost | About **$0.12/hour** while running (VMs $0.049/h each, IPs and disks extra) |
| Auto-shutdown | **09:00 IST daily.** The VMs deallocate, leaving only about $0.03/h for disks and IPs. |
| Teardown | `scripts/azure-quicktest.sh destroy` deletes the whole resource group |

How to look at it (details in [RUNBOOK.md](RUNBOOK.md)):

```bash
cd "d:/2026/sf infra"
ssh -N -f -i .local/azure-quicktest/id_ed25519 -L 16443:127.0.0.1:6443 scalesafe@20.219.131.118
export KUBECONFIG="$PWD/.local/azure-quicktest/kubeconfig-tunnel"
kubectl -n argocd port-forward svc/argocd-server 8080:80        # http://localhost:8080 (admin)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097   # http://localhost:9097
```

The cluster's Argo CD is currently pointed at the **in-cluster test Gitea**, from the e2e test. Gitea uses throwaway storage, so if its pod restarts, Argo CD will show repo errors. That's expected for a test cluster. Clean it up with `tests/e2e/run-e2e.sh cleanup`, or rebuild the cluster.

## Problems hit overnight, and how they were fixed

1. **Standard_B2s had no capacity in Central India.** The quick-test script now tries a list of fallback sizes, and the Terraform default is now B2as_v2, which worked.
2. **Tekton CRDs and their resources were in the same bundle**, so the first install failed. The bootstrap now applies, waits for CRDs to register, then applies again. Argo CD apps use `SkipDryRunOnMissingResource`.
3. **Direct connections to the Kubernetes API (port 6443) kept dropping from this network**, while SSH stayed stable. All scripts now retry, and the recommended access is an SSH tunnel. That also means 6443 can be closed publicly later.
4. **Argo CD showed Tekton apps as OutOfSync forever**, because Tekton's webhooks fill in defaults. Fixed with server-side diff (`ServerSideDiff=true,IncludeMutationWebhook=true`) on all apps.
5. **A placeholder image name in the smoke test was invalid** (uppercase). The build itself had worked; this is fixed.

## What is NOT done (needs you)

1. **Real values.** Run `scripts/configure.sh <github-org> <repo-url> <domain>`. It replaces `__GITHUB_ORG__`, `__GITOPS_REPO_URL__` and `__DOMAIN__`.
2. **GitHub.** Create the repo and push it yourself (I didn't push, per your instruction). Then `kubectl apply -f gitops/argocd/root.yaml`.
3. **Tokens.** Make a GitHub PAT (contents:write on the GitOps repo, write:packages for GHCR), then run `GITHUB_USER=… GITHUB_TOKEN=… GITOPS_REPO_URL=… scripts/create-ci-secrets.sh`.
4. **Cloudflare.** Create a zone-scoped API token, fill in `terraform/envs/cloudflare/terraform.tfvars`, and run `scripts/deploy.sh cloudflare apply`. Then set `web_cidrs` to Cloudflare's IP ranges (already listed in the tfvars examples).
5. **Not tested live: AWS and GCP.** No credentials were configured on this machine; only `terraform validate` passed. The cloud-init they use is the same one proven on Azure.
6. **Production hardening backlog.** TLS via cert-manager, Argo CD SSO, External Secrets, image signing and scanning, an HA control plane. See [SECURITY.md](SECURITY.md).
7. **Remote Terraform state.** It's local and gitignored for now; [STATE.md](STATE.md) has the commands for an encrypted Azure backend.

## Where things are

- Repo: `d:\2026\sf infra`. Local git is initialised; nothing is committed or pushed.
- Secrets (gitignored, never committed): `d:\2026\sf infra\.local\` holds the SSH key, k3s token, kubeconfigs, the test Gitea password and the test logs.
- Pinned versions: [versions.env](../versions.env)
- Overnight log: [PROGRESS.md](PROGRESS.md)
