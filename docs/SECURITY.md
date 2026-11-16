# Security controls

## In place now

**Network (every cloud)**
- SSH (22) and the Kubernetes API (6443) are open only to `admin_cidrs`. Terraform refuses `0.0.0.0/0`.
- Ports 80/443 are open only to `web_cidrs`. Behind Cloudflare, set these to Cloudflare's IP ranges so nobody can bypass the WAF by hitting the origin directly.
- Node-to-node traffic is limited to the private subnet. The AWS default security group is locked down.
- Pod and service CIDRs (10.42/16, 10.43/16) don't overlap the node VPCs (10.10, 10.20, 10.30).

**VM / OS** (`terraform/modules/k3s-cloudinit`)
- Ubuntu 24.04 LTS with automatic security updates (unattended-upgrades) and fail2ban.
- SSH is key-only: no passwords, no root login, MaxAuthTries 3.
- Kernel sysctls follow the CIS k3s guide; kubelet runs with `--protect-kernel-defaults`.
- Azure uses Trusted Launch (Secure Boot + vTPM). GCP uses Shielded VM, and its node service account has no roles. AWS uses IMDSv2 only, with encrypted gp3 disks.

**Kubernetes**
- Secrets are encrypted at rest (`secrets-encryption: true`).
- The API server rejects anonymous requests and writes an audit log (metadata level for secrets and configmaps) to `/var/lib/rancher/k3s/server/logs/audit.log`.
- The kubeconfig is mode 0600 on the server, and it is fetched over SSH only.
- Pod Security Admission levels:
  - App namespaces are `restricted`.
  - `ci` is `baseline`, because kaniko needs root but not privileged.
  - `argocd` is `baseline`.
- NetworkPolicies are default-deny ingress in app namespaces; only Traefik is allowed in.
- The `ci` namespace has a ResourceQuota and LimitRange, so runaway builds can't starve the cluster.

**CI (Tekton)**
- Images are built with kaniko: no Docker socket and no privileged pods.
- Registry and git credentials are mounted as optional workspaces only in the steps that need them, not on the ServiceAccount. `tekton-ci` has `automountServiceAccountToken: false`.
- The GitHub webhook HMAC is verified (`github` interceptor). Only pushes to `main` trigger builds.
- The Tekton Dashboard is installed **read-only**.
- Images are tagged with the commit short SHA. Avoid `:latest` in production overlays.

**CD (Argo CD)**
- RBAC defaults to `role:readonly`, anonymous access and exec are disabled, and admin is local-only until SSO is set up.
- AppProject `apps` is limited to namespaced resources in its allowed namespaces. Only `platform` may touch cluster-scoped objects.
- Argo CD isn't exposed publicly by default; use `kubectl port-forward`.

**Secrets & state**
- No secret ever goes in git (see `.gitignore`). Secrets come from environment variables through `scripts/create-ci-secrets.sh`.
- Terraform state holds the k3s token. Keep it local and gitignored now, then move it to an encrypted remote backend (see [STATE.md](STATE.md)).

## Hardening backlog (recommended next)

1. **TLS**: install cert-manager with a Let's Encrypt DNS-01 issuer through Cloudflare, then set the Cloudflare SSL mode to *Full (strict)*.
2. **SSO**: Argo CD with GitHub OAuth (dex), mapping the GitHub team to `role:admin`. Then remove the local admin.
3. **Sealed Secrets or External Secrets** (Azure Key Vault, AWS Secrets Manager, GCP Secret Manager), so secrets can live in GitOps too.
4. **Image signing**: Tekton Chains plus cosign, with verification by Kyverno or the sigstore policy-controller.
5. **Image scanning**: a Trivy task before push, failing on CRITICAL findings.
6. **Pin step images by digest** (`image@sha256:...`) instead of by tag.
7. **HA control plane**: 3 k3s servers with embedded etcd, plus etcd snapshots to object storage.
8. **Remove public IPs from agents**: NAT gateway, plus Cloudflare Tunnel or a load balancer for ingress.
9. **Kaniko**: the upstream project is archived. Plan a move to BuildKit rootless or the maintained kaniko fork.
