#!/usr/bin/env bash
# Creates the ScaleSafe runtime secrets in namespace `scalesafe`. Idempotent: existing DB passwords are
# kept (Postgres only reads them on first start), so re-running never locks services out.
#
#   KUBECONFIG=... PLATFORM_REPO=/path/to/scalesafe-platform scripts/scalesafe/secrets.sh
#
#   scalesafe-db         random password per service DB role + postgres superuser
#   scalesafe-keycloak   random Keycloak bootstrap admin password
#   scalesafe-oidc       confidential-client secrets, read from the realm file in the app repo
#   scalesafe-realm      ConfigMap: the app repo's realm export (application config, imported by Keycloak)
source "$(dirname "$0")/../lib/common.sh"
: "${PLATFORM_REPO:?set PLATFORM_REPO to the scalesafe-platform checkout}"
REALM="$PLATFORM_REPO/infra/keycloak/scalesafe-realm.json"
[[ -f "$REALM" ]] || die "realm export not found: $REALM"
NS=scalesafe

if ! kubectl -n $NS get secret scalesafe-db >/dev/null 2>&1; then
  args=()
  for k in postgres orchestrator clients kyc investors verification esign; do
    args+=(--from-literal="$k=$(random_token)")
  done
  kubectl -n $NS create secret generic scalesafe-db "${args[@]}" >/dev/null
  log "created scalesafe-db (random passwords)"
else
  log "scalesafe-db exists - keeping passwords"
fi

kubectl -n $NS get secret scalesafe-keycloak >/dev/null 2>&1 ||
  kubectl -n $NS create secret generic scalesafe-keycloak --from-literal=admin-password="$(random_token)" >/dev/null

# Client secrets must match what Keycloak imports from the realm file.
oidc_args=()
while IFS='=' read -r cid secret; do
  secret="${secret%$'\r'}"   # Windows Python prints CRLF; a stray \r breaks client authentication
  [[ -n "$cid" ]] && oidc_args+=(--from-literal="$cid=$secret")
done < <(python - "$(native_path "$REALM")" <<'PY'
import json, sys
for c in json.load(open(sys.argv[1], encoding="utf-8"))["clients"]:
    if not c.get("publicClient") and c.get("secret"):
        print(f'{c["clientId"]}={c["secret"]}')
PY
)
kubectl -n $NS create secret generic scalesafe-oidc "${oidc_args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS create configmap scalesafe-realm --from-file=scalesafe-realm.json="$REALM" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "secrets + realm ConfigMap ready in namespace $NS"
