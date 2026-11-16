# ScaleSafe CI/CD: code to production

Full version, with the flow diagram: https://claude.ai/artifact/KPYLAs2zEsig79BceQbHJK

Every change goes from `git push` to a healthy rollout through Git alone. Tekton builds and tests (CI), and Argo CD deploys (CD).

| | CI UI | CD UI |
|---|---|---|
| URL | `https://tekton.<domain>` | `https://argocd.<domain>` |
| Tool | Tekton Dashboard (read-only) | Argo CD |
| Sign-in | GitHub via oauth2-proxy, members of the org | "Log in via GitHub" (dex). Team `platform` = admin, others read-only |
| Manifests | `platform/ui/tekton-dashboard-*.yaml` | `platform/ui/argocd-ingress.yaml`, `platform/argocd/argocd-cm.yaml` |

## Flow

1. Merge to `main` in an app repo.
2. GitHub webhook → `https://hooks.<domain>/`; the Tekton interceptor checks the HMAC signature (main only).
3. Tekton `build-push-deploy`: clone, test, kaniko build (watch in the CI UI).
4. Push `ghcr.io/<org>/<app>:<git-sha>`.
5. The pipeline commits the new tag into `gitops/apps/scalesafe/overlays/dev`.
6. Argo CD syncs (watch in the CD UI).
7. Zero-downtime rollout; app shows Synced + Healthy. A blocked rollout stays visibly not healthy.

Roll back or promote: `scripts/scalesafe/set-version.sh <tag>` (≈80 s, exact same images). Never rebuild to roll back.

## Go-live checklist

1. Choose GitHub org, GitOps repo, domain → `scripts/configure.sh <org> <repo-url> <domain>`
2. Create the GitHub repos and push.
3. Cluster: `scripts/deploy.sh <cloud> apply` then `platform`.
4. GitHub token (contents:write on GitOps repo, write:packages) → `scripts/create-ci-secrets.sh`
5. Cloudflare DNS token → `scripts/deploy.sh cloudflare apply`
6. Cloudflare Origin CA cert for `tekton.` + `argocd.`; SSL mode Full (strict).
7. Two GitHub OAuth apps (callbacks in the header of `scripts/create-ui-secrets.sh`) → run that script.
8. `kubectl apply -f gitops/argocd/root.yaml` (Argo CD then manages `platform-ui` too).
9. Webhook on each app repo: `https://hooks.<domain>/`, JSON, push events.
10. First build: push to main; watch both UIs.
11. Lock down: verify SSO, set `admin.enabled: "false"`, delete `argocd-initial-admin-secret`.
12. Restrict 80/443 to Cloudflare IPs; close 6443 (use the SSH tunnel).

Not yet tested live: the public UI setup (`platform/ui`), pending DNS, certificate and OAuth apps.
