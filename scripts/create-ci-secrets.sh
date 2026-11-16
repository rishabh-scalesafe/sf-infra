#!/usr/bin/env bash
# Creates CI/CD secrets in-cluster from environment variables. Nothing is written to disk
# or to git. Re-run any time to rotate.
#
#   export GITHUB_USER=<bot or your username>
#   export GITHUB_TOKEN=<fine-grained PAT: contents:write on the gitops repo>
#   export GHCR_TOKEN=<classic PAT with write:packages, or same token if it has packages:write>
#   KUBECONFIG=... scripts/create-ci-secrets.sh
#
# Creates:
#   ci/ghcr-push               dockerconfigjson  (Tekton kaniko push)
#   ci/git-credentials         .git-credentials  (clone private repos + push GitOps bumps)
#   ci/github-webhook-secret   random token      (validates GitHub webhook signatures)
#   sample-app/ghcr-pull       dockerconfigjson  (pull private images; read-only use)
#   argocd repo secret         lets Argo CD read the private GitOps repo
source "$(dirname "$0")/lib/common.sh"

: "${GITHUB_USER:?set GITHUB_USER}"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN}"
GHCR_TOKEN="${GHCR_TOKEN:-$GITHUB_TOKEN}"
GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"

apply() { kubectl apply -f - >/dev/null; }

kubectl -n ci create secret docker-registry ghcr-push \
  --docker-server=ghcr.io --docker-username="$GITHUB_USER" --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | apply

kubectl -n sample-app create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$GITHUB_USER" --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | apply

kubectl -n ci create secret generic git-credentials \
  --from-literal=.git-credentials="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" \
  --from-literal=.gitconfig=$'[credential]\n\thelper = store\n' \
  --dry-run=client -o yaml | apply

if ! kubectl -n ci get secret github-webhook-secret >/dev/null 2>&1; then
  kubectl -n ci create secret generic github-webhook-secret --from-literal=token="$(random_token)"
fi

if [[ -n "$GITOPS_REPO_URL" ]]; then
  kubectl -n argocd create secret generic gitops-repo \
    --from-literal=type=git --from-literal=url="$GITOPS_REPO_URL" \
    --from-literal=username="$GITHUB_USER" --from-literal=password="$GITHUB_TOKEN" \
    --dry-run=client -o yaml | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | apply
fi

log "Secrets created."
log "GitHub webhook secret (paste into repo Settings > Webhooks):"
kubectl -n ci get secret github-webhook-secret -o jsonpath='{.data.token}' | base64 -d; echo
