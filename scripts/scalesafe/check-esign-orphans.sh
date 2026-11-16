#!/usr/bin/env bash
# Read-only check for the downgrade data issue found on 2026-11-16: signing requests that an esign-service
# image OLDER than migration V2 created while the schema was already at V2. Such requests have no rows in
# signing_documents, so the current code cannot show the investor what they are asked to sign
# (GET /api/v1/sign/{token}/documents/{type} has nothing to serve).
#
#   KUBECONFIG=... scripts/scalesafe/check-esign-orphans.sh
# Repair (application-level, not done automatically): the affected investor declines / the case is
# re-submitted so a fresh request is issued by the current esign-service; or add a "re-issue signing
# request" operation to esign-service. The downgrade guard in gen-manifests.py prevents new cases.
source "$(dirname "$0")/../lib/common.sh"
kubectl -n scalesafe exec postgres-0 -- psql -U postgres -d scalesafe -P pager=off -c "
SELECT r.id, r.reference, r.status, r.created_at
FROM esign.signing_requests r
WHERE NOT EXISTS (SELECT 1 FROM esign.signing_documents d WHERE d.request_id = r.id)
  AND r.created_at > (SELECT installed_on FROM esign.flyway_schema_history WHERE version = '2')
ORDER BY r.created_at;"
