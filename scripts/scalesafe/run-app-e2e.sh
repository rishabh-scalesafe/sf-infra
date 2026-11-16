#!/usr/bin/env bash
# Run the ScaleSafe application's own e2e suites (from the app repo, read-only) against the cluster
# through scripts/tunnel.sh. Test users come from the realm export. The investor suite's defaults
# (maker1@scalesafe.test ...) do not exist in that realm, and its "maker cannot decide own case" check
# needs a maker who ALSO holds firm-checker - in this realm that is firmadmin1@acme.test.
#   PLATFORM_REPO=... scripts/scalesafe/run-app-e2e.sh <label>
source "$(dirname "$0")/../lib/common.sh"
set +e
: "${PLATFORM_REPO:?}"
LABEL="${1:-run}"
mkdir -p "$REPO_ROOT/.local/tmp"
# Native Windows curl cannot read MSYS /tmp paths in -F file=@...; use a mixed-style temp dir.
export TMPDIR="$(cygpath -m "$REPO_ROOT/.local/tmp" 2>/dev/null || echo "$REPO_ROOT/.local/tmp")"
export E2E_MAKER_USER=firmadmin1@acme.test E2E_MAKER_PASS='FirmAdmin#2026'
export E2E_CHECKER_USER=checker1@acme.test E2E_MAKERB_USER=maker1@beta.test
# Warm-up: after pods are replaced, the node-side port-forwards reconnect on first use.
for i in 1 2 3 4 5; do
  okc=0
  for p in 8180 8081 8082 8083 8084 8085 8086; do
    [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://localhost:$p/")" != 000 ]] && okc=$((okc + 1))
  done
  [[ $okc -eq 7 ]] && break
  sleep 5
done
rc=0
for suite in ${SUITES:-e2e e2e-investor}; do
  out="$REPO_ROOT/.local/ss-$suite-$LABEL.log"
  timeout 900 bash "$PLATFORM_REPO/tools/$suite.sh" > "$out" 2>&1; r=$?
  res="$(grep -a 'RESULT' "$out" | tail -1)"
  log "$suite: ${res:-no RESULT line} (exit $r)"
  grep -a 'FAIL' "$out" | head -10 >&2
  [[ $r -ne 0 ]] && rc=1
done
exit $rc
