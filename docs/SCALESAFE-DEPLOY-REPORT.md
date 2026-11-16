# ScaleSafe: build, deploy, downgrade (test run 16 Nov 2026, 02:20–03:45 IST)

**Result:** all of ScaleSafe was built and deployed through this repo's Tekton → GitOps → Argo CD pipeline onto the Azure test cluster. It was then downgraded. The downgrade exposed a real data-integrity problem, which is now fixed in the infrastructure and covered by a detection check. The final state is the current version, healthy, with the application's own test suites at **47/47 and 125/125**.

All the Kubernetes manifests were written for this repo (`scripts/scalesafe/gen-manifests.py`, which generates `gitops/apps/scalesafe/`). Nothing was copied from the application repos' `deploy/` or `infra/` folders. The only thing taken from the app repo is its Keycloak realm export, which is application config: Keycloak imports it as a ConfigMap at deploy time.

## What was deployed

| Component | Source | Image tag |
|---|---|---|
| orchestrator, client-service, kyc-service, investor-service, verification-service, esign-service | `scalesafe-platform` @ 7dc0462 | `7dc0462` |
| web-app (client portal), web-admin (admin console) | `scalesafe-platform` @ 7dc0462 | `7dc0462` |
| site (corporate site) | `scalesafe` @ 2a31c94 | `2a31c94` |
| Postgres 17 (one schema and role per service; generated passwords), Keycloak 26.0.7 | public images | — |

- **Namespace:** `scalesafe`, at Pod Security `restricted`. Every pod runs non-root with all capabilities dropped; the services also run with a read-only root filesystem.
- **NetworkPolicy:** default-deny ingress, with traffic allowed inside the namespace.
- **Secrets:** random DB and Keycloak admin passwords, never stored in git.
- **Build:** 9 images in 8.5 minutes, 2 at a time, through the standard `build-push-deploy` pipeline. Each build commits its new image tag to the GitOps repo, and Argo CD rolls it out.

Code never went to GitHub. A throwaway in-cluster Gitea and registry stood in for GitHub and GHCR.

## Test evidence

| Step | Version | Client onboarding saga (`tools/e2e.sh`) | Investor onboarding (`tools/e2e-investor.sh`) |
|---|---|---|---|
| Deploy | 7dc0462 | **47/47** | **125/125** |
| Downgrade (rebuild old commit) | 273b1a2 | **47/47** | Fails on features that version doesn't have yet (`/api/v1/tenant` 404, signing inbox). Expected. |
| Roll forward (re-pin, no rebuild, 83 s) | 7dc0462 | **47/47** | **125/125** |
| Guarded downgrade, then roll forward (79 s) | 7dc0462 | **47/47** | **125/125** |

## The issue the downgrade found

**What happened**
- In the newer version, esign-service migration **V2** added `signing_documents`, which holds the exact text of each document an investor signs.
- Downgrading esign-service to `273b1a2` (V1 code) **started without complaint**. Flyway ignores "future" migrations by default, so it only logged a WARN.
- While downgraded, the old code created a signing request (`ACME-2026-000006`) **with no rows in `signing_documents`**.
- After upgrading back, the current code serves document text from that table (`GET /api/v1/sign/{token}/documents/{type}`). For that request, the investor would be asked to sign documents the system can't show them. The text was never stored, so a backfill can't fix it.
- Argo CD showed everything as **Healthy** the whole time.

**Fix (infrastructure, in `scripts/scalesafe/gen-manifests.py`)**
1. **Downgrade guard:** `SPRING_FLYWAY_IGNORE_MIGRATION_PATTERNS=*:pending` on every service. Now only not-yet-applied migrations are tolerated. An image older than its schema fails startup with `Detected applied migration not resolved locally: 2`.
2. **Zero-downtime rollout:** `maxUnavailable: 0, maxSurge: 1, progressDeadlineSeconds: 600`. The blocked pod is never marked Ready, so the current pod keeps serving, and Argo CD reports the rollout as not healthy instead of hiding it.

   *Verified:* the same downgrade with the guard in place left esign-service on `7dc0462` (Ready, serving), with the `273b1a2` pod crash-looping on the Flyway validation error. The five services whose schemas were unchanged downgraded normally. No bad rows were written.
3. **Detection:** `scripts/scalesafe/check-esign-orphans.sh` (read-only) lists affected requests. It found exactly the one written before the guard existed.

**Still needs an application-side decision.** For the one affected request: have the case re-submitted so the current esign-service issues a fresh request, or add a "re-issue signing request" operation to esign-service. I did not change application code.

## The second finding: how to roll back

The first downgrade rebuilt the old commit: about **10 minutes** for 9 images. That does **not** reproduce the artifact that originally ran, because base images and `apk upgrade` move on. `scripts/scalesafe/set-version.sh` rolls back or promotes by **re-pinning image tags that already exist in Git**. It checks the registry first, then makes one commit, and Argo CD does the rest. It took **79–83 seconds** end to end and gives back exactly the same images.

**Rule:** roll back with `set-version.sh <previous-tag>`. Rebuild only for a genuinely new commit.

## Other problems hit and fixed during the run

| Problem | Fix |
|---|---|
| OIDC client secrets got a trailing `\r`, because Windows Python prints CRLF. Every service's token request returned 401 and saga registration failed. | Strip `\r` in `scripts/scalesafe/secrets.sh` |
| Dev access through the tunnel couldn't reach pods on the other node: the namespace's default-deny NetworkPolicy (correctly) drops node-sourced traffic | `scripts/tunnel.sh` now runs `kubectl port-forward` on the server node (through the kubelet, not affected by NetworkPolicy); SSH carries only node-local ports. NetworkPolicy was not weakened. |
| Tunnel port collision (8081 and 18081 mapped to the same node port) | Node ports assigned by position in the list |
| `kubectl port-forward` from this PC kept dying on the flaky link | Everything goes through the SSH tunnel |
| Kaniko Maven builds would exceed the `ci` namespace's 1 Gi default memory limit | Kaniko step requests 1.5 Gi, limit 3.5 Gi |
| ResourceQuota rejected pods whose init container had no limits | Init containers have requests and limits |
| App test suites on Windows: native curl can't read `/tmp/...` uploads; investor suite's default users don't exist in the realm | `scripts/scalesafe/run-app-e2e.sh` sets a `D:/...` temp dir and uses the realm's users (a maker with the checker role for the maker≠checker check) |
| The app repo's `tools/e2e.sh` at 273b1a2 reads `$CODE` from a subshell, so it reports false failures | App test bug in the old version, already gone in newer versions; noted for the app team |
| A GitOps commit made from Windows converted the whole repo to CRLF | Fixed forward with an LF-restoring commit; `set-version.sh` pins `core.autocrlf=false` |

## How to repeat it

```bash
export KUBECONFIG=.local/azure-quicktest/kubeconfig-tunnel           # while scripts/tunnel.sh runs
PLATFORM_REPO=../scalesafe-platform scripts/scalesafe/secrets.sh
PLATFORM_REPO=../scalesafe-platform SITE_REPO=../scalesafe scripts/scalesafe/push-sources.sh
PLATFORM_URL=... SITE_URL=... IMAGE_PREFIX=... GITOPS_URL=... scripts/scalesafe/build.sh <sha> <site-sha>
PLATFORM_REPO=../scalesafe-platform scripts/scalesafe/run-app-e2e.sh <label>
GITOPS_PUSH_URL=... scripts/scalesafe/set-version.sh <tag> [site-tag]   # rollback / promote
scripts/scalesafe/check-esign-orphans.sh
```

For production, point `IMAGE_PREFIX` at `ghcr.io/<org>`, `GITOPS_URL` at the GitHub repo, and the source URLs at GitHub. Use `INSECURE_REGISTRY=false` (the default).
