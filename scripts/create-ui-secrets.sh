#!/usr/bin/env bash
# Secrets for the public CI/CD UIs (platform/ui). Nothing is written to disk or git.
# Re-run any time to rotate.
#
# 1. Cloudflare > SSL/TLS > Origin Server > Create certificate for
#    tekton.<domain>, argocd.<domain> (or *.<domain>). Save the two PEM files locally.
# 2. GitHub > Settings > Developer settings > OAuth Apps: create TWO apps
#      Tekton UI : homepage https://tekton.<domain>  callback https://tekton.<domain>/oauth2/callback
#      Argo CD   : homepage https://argocd.<domain>  callback https://argocd.<domain>/api/dex/callback
#
#   export ORIGIN_CERT=/path/origin.pem ORIGIN_KEY=/path/origin.key
#   export TEKTON_OAUTH_CLIENT_ID=... TEKTON_OAUTH_CLIENT_SECRET=...
#   export ARGOCD_OAUTH_CLIENT_ID=... ARGOCD_OAUTH_CLIENT_SECRET=...
#   KUBECONFIG=... scripts/create-ui-secrets.sh
#
# Creates:
#   tekton-pipelines/origin-tls, argocd/origin-tls   Cloudflare Origin CA cert (Full strict)
#   tekton-pipelines/oauth2-proxy-tekton             GitHub OAuth app + cookie secret
#   argocd/argocd-secret keys dex.github.clientID / dex.github.clientSecret
source "$(dirname "$0")/lib/common.sh"

: "${ORIGIN_CERT:?set ORIGIN_CERT (path to Cloudflare origin certificate PEM)}"
: "${ORIGIN_KEY:?set ORIGIN_KEY (path to its private key)}"
: "${TEKTON_OAUTH_CLIENT_ID:?set TEKTON_OAUTH_CLIENT_ID}"
: "${TEKTON_OAUTH_CLIENT_SECRET:?set TEKTON_OAUTH_CLIENT_SECRET}"
[[ -f "$ORIGIN_CERT" && -f "$ORIGIN_KEY" ]] || die "ORIGIN_CERT / ORIGIN_KEY must be readable files"

apply() { kubectl apply -f - >/dev/null; }

for ns in tekton-pipelines argocd; do
  kubectl -n "$ns" create secret tls origin-tls --cert="$ORIGIN_CERT" --key="$ORIGIN_KEY" \
    --dry-run=client -o yaml | apply
  log "origin-tls -> $ns"
done

# oauth2-proxy needs a cookie secret of exactly 16, 24 or 32 bytes: 32 hex chars = 32 bytes.
COOKIE_SECRET="$(openssl rand -hex 16)"
kubectl -n tekton-pipelines create secret generic oauth2-proxy-tekton \
  --from-literal=client-id="$TEKTON_OAUTH_CLIENT_ID" \
  --from-literal=client-secret="$TEKTON_OAUTH_CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --dry-run=client -o yaml | apply
kubectl -n tekton-pipelines rollout restart deploy/tekton-dashboard-auth >/dev/null 2>&1 || true
log "oauth2-proxy-tekton -> tekton-pipelines"

if [[ -n "${ARGOCD_OAUTH_CLIENT_ID:-}" && -n "${ARGOCD_OAUTH_CLIENT_SECRET:-}" ]]; then
  kubectl -n argocd patch secret argocd-secret --type merge -p "$(printf \
    '{"stringData":{"dex.github.clientID":"%s","dex.github.clientSecret":"%s"}}' \
    "$ARGOCD_OAUTH_CLIENT_ID" "$ARGOCD_OAUTH_CLIENT_SECRET")" >/dev/null
  kubectl -n argocd rollout restart deploy/argocd-dex-server >/dev/null
  log "Argo CD GitHub SSO credentials -> argocd/argocd-secret"
else
  warn "ARGOCD_OAUTH_CLIENT_ID/SECRET not set: Argo CD keeps local admin login only"
fi

log "Done. Check: https://tekton.<domain> (GitHub sign-in) and https://argocd.<domain> (LOG IN VIA GITHUB)"
