# Runbook

## Access the Azure quick-test cluster

```bash
cd "d:/2026/sf infra"
export KUBECONFIG="$PWD/.local/azure-quicktest/kubeconfig"
kubectl get nodes

# Argo CD UI
kubectl -n argocd port-forward svc/argocd-server 8080:80        # http://localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Tekton Dashboard (read-only)
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097   # http://localhost:9097

# SSH to the server
ssh -i .local/azure-quicktest/id_ed25519 scalesafe@<server-ip>
```

**Recommended: reach the API through an SSH tunnel.** Overnight, this ISP connection kept dropping direct connections to port 6443 while SSH stayed stable. A tunnel fixes that, and it means 6443 can later be closed in the NSG entirely:

```bash
ssh -N -f -i .local/azure-quicktest/id_ed25519 -L 16443:127.0.0.1:6443 scalesafe@<server-ip>
export KUBECONFIG="$PWD/.local/azure-quicktest/kubeconfig-tunnel"   # server: https://127.0.0.1:16443
```

**If your public IP changed** (mobile or home ISP), the NSG will block you. Update the rules:

```bash
MYIP=$(curl -s https://api.ipify.org)/32
for r in ssh-admin kubeapi-admin web; do
  az network nsg rule update -g sf-infra-qt-rg --nsg-name sfqt-nsg -n $r --source-address-prefixes $MYIP
done
```

**Auto-shutdown**: the quick-test VMs deallocate daily at 09:00 IST (03:30 UTC), so they don't run up costs. To start them again:

```bash
az vm start -g sf-infra-qt-rg --ids $(az vm list -g sf-infra-qt-rg --query "[].id" -o tsv)
```

**Delete the quick-test cluster completely:**

```bash
scripts/azure-quicktest.sh destroy
```

## Public CI and CD UIs

Once DNS points at the cluster (`tekton` and `argocd` are already in the Cloudflare hostnames):

| UI | URL | Sign-in |
|---|---|---|
| CI: Tekton Dashboard (read-only) | `https://tekton.<domain>` | GitHub, members of the org (oauth2-proxy) |
| CD: Argo CD | `https://argocd.<domain>` | "Log in via GitHub" (dex). Team `platform` = admin, other org members = read-only |

Set up once: `scripts/create-ui-secrets.sh` (Cloudflare origin certificate + two GitHub OAuth apps; steps in the script header), then Cloudflare SSL/TLS mode **Full (strict)**. Argo CD deploys `platform/ui` itself through the `platform-ui` app.

After GitHub SSO works for an admin, set `admin.enabled: "false"` in `platform/argocd/argocd-cm.yaml`, commit, and delete `argocd-initial-admin-secret`.

The full code-to-production flow is in [CICD-FLOW.md](CICD-FLOW.md).

## Run CI by hand

```bash
kubectl create -f tekton/tests/smoke-pipelinerun.yaml                       # build only, no push
kubectl -n ci get pipelineruns
kubectl -n ci logs -l tekton.dev/pipelineRun=<name> --all-containers -f
```

Full build, push to GHCR and GitOps bump (needs the secrets from `create-ci-secrets.sh`):

```bash
cat <<EOF | kubectl create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata: {generateName: manual-, namespace: ci}
spec:
  pipelineRef: {name: build-push-deploy}
  taskRunTemplate: {serviceAccountName: tekton-ci}
  params:
    - {name: repo-url, value: https://github.com/<org>/sample-app.git}
    - {name: image, value: ghcr.io/<org>/sample-app}
    - {name: gitops-repo-url, value: https://github.com/<org>/sf-infra.git}
    - {name: gitops-path, value: gitops/apps/sample-app/overlays/prod}
  workspaces:
    - name: source
      volumeClaimTemplate: {spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}}
    - name: git-credentials
      secret: {secretName: git-credentials}
    - name: dockerconfig
      secret: {secretName: ghcr-push, items: [{key: .dockerconfigjson, path: config.json}]}
EOF
```

## Upgrades

1. Bump the version in `versions.env` **and** in the matching URL (`platform/tekton/kustomization.yaml`, `platform/argocd/kustomization.yaml`, `k3s_version` tfvars). Use releases that are at least 2 weeks old.
2. Test on the quick-test cluster: `scripts/bootstrap-platform.sh && scripts/smoke-test.sh`.
3. Commit, and Argo CD rolls it out.
4. Upgrade k3s with the system-upgrade-controller, or node by node (`curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=... sh -`), server first.

## Rotate secrets

- CI tokens: export new values and re-run `scripts/create-ci-secrets.sh`.
- Webhook secret: `kubectl -n ci delete secret github-webhook-secret`, re-run the script, then update the GitHub webhook.
- k3s token: `k3s token rotate` on the server (see the k3s docs), then update Terraform state.

## Scale

Change `agent_count` in tfvars and run `scripts/deploy.sh <cloud> apply`. New agents join on their own.
