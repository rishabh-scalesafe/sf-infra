#!/usr/bin/env bash
# End-to-end smoke test of a cluster built with this repo. Prints PASS/FAIL per check.
#   KUBECONFIG=... scripts/smoke-test.sh
source "$(dirname "$0")/lib/common.sh"
cd "$REPO_ROOT"
set +e
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then log "PASS  $name"; ((PASS++)); else warn "FAIL  $name"; ((FAIL++)); fi; }

nodes_ready()  { ! kubectl get nodes --no-headers | grep -v ' Ready'; }
pods_healthy() { ! kubectl get pods -n "$1" --no-headers | grep -vE 'Running|Completed'; }

check "all nodes Ready"                 nodes_ready
check "kube-system pods healthy"        pods_healthy kube-system
check "tekton-pipelines pods healthy"   pods_healthy tekton-pipelines
check "argocd pods healthy"             pods_healthy argocd
check "tekton pipeline registered"      kubectl -n ci get pipeline build-push-deploy
check "eventlistener ready"             kubectl -n ci wait --for=condition=Ready eventlistener/github --timeout=180s

# --- CI: run the real pipeline (build only) against a public repo
run_ci() {
  local pr
  pr="$(kubectl create -f tekton/tests/smoke-pipelinerun.yaml -o jsonpath='{.metadata.name}')" || return 1
  log "PipelineRun $pr started"
  local st="Unknown" i
  for i in $(seq 1 120); do   # up to 20 min; stops as soon as the run finishes (pass or fail)
    st="$(kubectl -n ci get pipelinerun "$pr" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo Unknown)"
    [[ "$st" == True || "$st" == False ]] && break
    sleep 10
  done
  local rc=1; [[ "$st" == True ]] && rc=0
  [[ $rc -ne 0 ]] && kubectl -n ci logs -l "tekton.dev/pipelineRun=$pr" --all-containers --tail=20
  kubectl -n ci get pipelinerun "$pr" -o wide
  kubectl -n ci get taskrun -l "tekton.dev/pipelineRun=$pr"
  return $rc
}
check "tekton pipeline clone->test->kaniko build" run_ci

# --- CD: Argo CD syncs an app from Git (public example repo; ours is not on GitHub yet)
run_cd() {
  kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: smoke-guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: smoke-guestbook
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true]
EOF
  local i
  for i in $(seq 1 40); do
    local s h
    s="$(kubectl -n argocd get application smoke-guestbook -o jsonpath='{.status.sync.status}')"
    h="$(kubectl -n argocd get application smoke-guestbook -o jsonpath='{.status.health.status}')"
    log "argocd smoke-guestbook sync=$s health=$h"
    [[ "$s" == Synced && "$h" == Healthy ]] && return 0
    sleep 15
  done
  return 1
}
check "argo cd git sync -> Healthy app" run_cd

# --- our own GitOps app manifests (quicktest overlay, restricted PSA namespace)
run_app() {
  kubectl apply -k gitops/apps/sample-app/overlays/quicktest || return 1
  kubectl -n sample-app rollout status deploy/sample-app --timeout=300s || return 1
  kubectl -n sample-app port-forward svc/sample-app 18080:80 >/dev/null 2>&1 &
  local pf=$! code
  sleep 5
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/)"
  kill $pf 2>/dev/null
  log "sample-app HTTP $code"
  [[ "$code" == 200 ]]
}
check "sample-app (restricted PSA, netpol) serves HTTP 200" run_app

# --- Optional node-level checks over SSH: SMOKE_SSH="ssh -i key user@ip"
if [[ -n "${SMOKE_SSH:-}" ]]; then
  check "k3s secrets encryption enabled" bash -c "$SMOKE_SSH 'sudo k3s secrets-encrypt status' | grep -q 'Encryption Status: Enabled'"
  check "ssh password auth disabled"     bash -c "$SMOKE_SSH 'sudo sshd -T' | grep -qi '^passwordauthentication no'"
  check "apiserver audit log written"    bash -c "$SMOKE_SSH 'sudo test -s /var/lib/rancher/k3s/server/logs/audit.log'"
fi

echo
log "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
