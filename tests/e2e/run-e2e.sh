#!/usr/bin/env bash
# FULL GitOps loop on a live cluster, without GitHub/GHCR (Gitea + registry stand in):
#
#   git push (app) --webhook--> Tekton EventListener --> clone -> test -> kaniko build
#   --> push image to registry --> commit newTag to GitOps repo --> Argo CD (root app-of-apps
#   from THIS repo) syncs --> Deployment runs the new image --> HTTP 200
#
#   KUBECONFIG=... SSH_KEY=<key> SERVER_IP=<ip> AGENT_IP=<ip> tests/e2e/run-e2e.sh
#   tests/e2e/run-e2e.sh cleanup
source "$(dirname "$0")/../../scripts/lib/common.sh"
cd "$REPO_ROOT"
set +e

WORK="$REPO_ROOT/.local/e2e-work"
GITEA_USER=scalesafe
PASS=0; FAIL=0
wait_soft() { # like wait_for but returns 1 instead of exiting
  local timeout="$1" desc="$2" start=$SECONDS; shift 2
  until "$@"; do (( SECONDS - start > timeout )) && { warn "timeout: $desc"; return 1; }; sleep 15; done
}
# Port access: with USE_TUNNEL=1, scripts/tunnel.sh already serves the ports (stable on flaky links);
# otherwise fall back to kubectl port-forward.
pf() { # pf <ns> <svc> <local:remote>  -> runs in background
  if [[ "${USE_TUNNEL:-0}" == 1 ]]; then sleep 1; else kubectl -n "$1" port-forward "svc/$2" "$3" >/dev/null 2>&1; fi
}
check() { local n="$1"; shift; if "$@"; then log "PASS  $n"; ((PASS++)); else warn "FAIL  $n"; ((FAIL++)); fi; }

if [[ "${1:-}" == cleanup ]]; then
  kubectl -n argocd patch application root --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
  kubectl -n argocd delete application root sample-app --wait=false 2>/dev/null
  kubectl delete ns e2e --wait=false
  log "cleanup requested (platform apps stay; they are the same manifests)"
  exit 0
fi

# ------------------------------------------------------------------ 1. Gitea + registry
log "1. deploying Gitea + registry (test stand-ins for GitHub + GHCR)"
retry 3 kubectl apply -f tests/e2e/infra.yaml >/dev/null
retry 3 kubectl -n e2e rollout status deploy/gitea --timeout=300s
retry 3 kubectl -n e2e rollout status deploy/registry --timeout=300s

GITEA_PW_FILE="$REPO_ROOT/.local/e2e-gitea-pw"
[[ -f "$GITEA_PW_FILE" ]] || random_token > "$GITEA_PW_FILE"
GITEA_PW="$(tr -d '\r\n' < "$GITEA_PW_FILE")"
# exec starts in / - Gitea's CLI needs its work path explicitly.
kubectl -n e2e exec deploy/gitea -- sh -c "cd /var/lib/gitea && gitea --work-path /var/lib/gitea \
  --config /etc/gitea/app.ini admin user create --username '$GITEA_USER' --password '$GITEA_PW' \
  --email e2e@example.invalid --admin --must-change-password=false" >/dev/null 2>&1 || log "gitea user exists"

# ------------------------------------------------------------------ 2. let nodes pull from the test registry
REG_IP="$(kubectl -n e2e get svc registry -o jsonpath='{.spec.clusterIP}')"
REGCFG="mirrors:
  \"registry.e2e.svc:5000\":
    endpoint:
      - \"http://$REG_IP:5000\""
node_ssh() { # node_ssh <ip> <remote command>   (stdin is forwarded)
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=15 "${SSH_USER:-scalesafe}@$1" "$2"
}
for node in "k3s:${SERVER_IP:-}" "k3s-agent:${AGENT_IP:-}"; do
  svc="${node%%:*}"; ip="${node#*:}"
  [[ -z "$ip" || -z "${SSH_KEY:-}" ]] && continue
  if ! node_ssh "$ip" "sudo grep -q '$REG_IP' /etc/rancher/k3s/registries.yaml 2>/dev/null" </dev/null; then
    log "2. configuring containerd mirror on $ip ($svc) -> $REG_IP"
    printf '%s\n' "$REGCFG" | node_ssh "$ip" "sudo tee /etc/rancher/k3s/registries.yaml >/dev/null && sudo systemctl restart $svc" ||
      warn "could not configure $ip"
  fi
done
sleep 20
wait_for 300 "API back after k3s restart" kubectl get nodes

# ------------------------------------------------------------------ 3. GitOps repo = copy of THIS repo, configured for the test
log "3. preparing GitOps repo copy"
rm -rf "$WORK"; mkdir -p "$WORK"
python - "$REPO_ROOT" "$WORK/sf-infra" <<'PY'
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], ignore=shutil.ignore_patterns('.local', '.git', '.terraform', '*.tfstate*'))
PY
GITOPS_URL="http://gitea.e2e.svc:3000/$GITEA_USER/sf-infra.git"
(
  cd "$WORK/sf-infra"
  grep -rl 'ghcr.io/__GITHUB_ORG__' gitops tekton | xargs sed -i "s#ghcr.io/__GITHUB_ORG__#registry.e2e.svc:5000/$GITEA_USER#g"
  python - <<'PY'
p = 'tekton/triggers/github-push.yaml'
s = open(p).read()
anchor = "          - name: gitops-path\n            value: gitops/apps/$(tt.params.repo-name)/overlays/prod\n"
assert anchor in s
s = s.replace(anchor, anchor + "          - name: insecure-registry\n            value: \"true\"\n")
open(p, 'w', newline='\n').write(s)
PY
  ./scripts/configure.sh "$GITEA_USER" "$GITOPS_URL" quicktest.local >/dev/null
  git init -q -b main . && git add -A && git -c user.name=e2e -c user.email=e2e@example.invalid commit -qm "initial"
)

# sample application repo
mkdir -p "$WORK/sample-app"
cat > "$WORK/sample-app/Dockerfile" <<'EOF'
FROM docker.io/nginxinc/nginx-unprivileged:1.29-alpine
COPY index.html /usr/share/nginx/html/index.html
EOF
echo "<h1>ScaleSafe sample-app - deployed by Tekton + Argo CD</h1>" > "$WORK/sample-app/index.html"
(cd "$WORK/sample-app" && git init -q -b main . && git add -A && git -c user.name=e2e -c user.email=e2e@example.invalid commit -qm "app v1")

pf e2e gitea 13000:3000 & PF=$!
sleep 6
push() { git -C "$1" push -q -f "http://$GITEA_USER:$GITEA_PW@127.0.0.1:13000/$GITEA_USER/$2.git" main; }
check "push GitOps repo to Gitea"  retry 3 push "$WORK/sf-infra" sf-infra
check "push app repo to Gitea"     retry 3 push "$WORK/sample-app" sample-app
APP_SHA="$(git -C "$WORK/sample-app" rev-parse HEAD)"; SHORT="${APP_SHA:0:7}"

# ------------------------------------------------------------------ 4. CI secrets (test values)
kubectl -n ci create secret generic git-credentials \
  --from-literal=.git-credentials="http://$GITEA_USER:$GITEA_PW@gitea.e2e.svc:3000" \
  --from-literal=.gitconfig=$'[credential]\n\thelper = store\n' --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n ci create secret docker-registry ghcr-push --docker-server=registry.e2e.svc:5000 \
  --docker-username=none --docker-password=none --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n ci get secret github-webhook-secret >/dev/null 2>&1 ||
  kubectl -n ci create secret generic github-webhook-secret --from-literal=token="$(random_token)" >/dev/null

# ------------------------------------------------------------------ 5. hand the cluster to Argo CD (app-of-apps)
log "5. applying root app-of-apps from the GitOps repo"
retry 3 kubectl apply --server-side -f "$WORK/sf-infra/gitops/argocd/projects/" >/dev/null
retry 3 kubectl apply -f "$WORK/sf-infra/gitops/argocd/root.yaml" >/dev/null
apps_synced() {
  local out; out="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}{"\n"}{end}')"
  echo "$out" | tr '\n' ' ' >&2; echo >&2
  for a in root argocd platform-namespaces tekton ci-pipelines sample-app; do
    echo "$out" | grep -q "^$a=Synced$" || return 1
  done
}
check "Argo CD app-of-apps: all 6 apps Synced" wait_soft 600 "argo apps synced" apps_synced

# ------------------------------------------------------------------ 6. GitHub-style signed webhook -> Tekton
log "6. sending signed push webhook for sample-app@$SHORT"
SECRET="$(kubectl -n ci get secret github-webhook-secret -o jsonpath='{.data.token}' | base64 -d)"
BODY="{\"ref\":\"refs/heads/main\",\"after\":\"$APP_SHA\",\"deleted\":false,\"repository\":{\"name\":\"sample-app\",\"clone_url\":\"http://gitea.e2e.svc:3000/$GITEA_USER/sample-app.git\"}}"
SIG="sha256=$(printf '%s' "$BODY" | python -c "import sys,hmac,hashlib;print(hmac.new(sys.argv[1].encode(),sys.stdin.buffer.read(),hashlib.sha256).hexdigest())" "$SECRET")"
kubectl -n ci delete pipelinerun -l scalesafe.io/app=sample-app >/dev/null 2>&1
pf ci el-github 18081:8080 & PF2=$!
sleep 6
send_hook() { curl -fsS -o /dev/null -X POST http://127.0.0.1:18081 -H 'X-GitHub-Event: push' \
  -H "X-Hub-Signature-256: $SIG" -H 'Content-Type: application/json' -d "$BODY"; }
check "webhook accepted" retry 3 send_hook
kill $PF2 2>/dev/null

pr_done() {
  local st; st="$(kubectl -n ci get pipelinerun -l scalesafe.io/app=sample-app -o jsonpath='{.items[0].status.conditions[0].status}' 2>/dev/null)"
  log "pipelinerun status=${st:-pending}"
  [[ "$st" == True ]] && return 0
  [[ "$st" == False ]] && { kubectl -n ci logs -l scalesafe.io/app=sample-app --all-containers --tail=30 >&2; return 2; }
  return 1
}
pr_wait() { local i rc; for i in $(seq 1 90); do pr_done; rc=$?; [[ $rc -eq 0 ]] && return 0; [[ $rc -eq 2 ]] && return 1; sleep 10; done; return 1; }
check "Tekton: clone -> test -> build -> push -> gitops bump" pr_wait
kubectl -n ci get taskrun -l scalesafe.io/app=sample-app

# ------------------------------------------------------------------ 7. verify artefacts + CD
pf e2e registry 15000:5000 & PF3=$!
sleep 5
check "image sample-app:$SHORT in registry" bash -c "curl -fsS http://127.0.0.1:15000/v2/$GITEA_USER/sample-app/tags/list | tee -a '$REPO_ROOT/.local/e2e-evidence.log' | grep -q '$SHORT'"
kill $PF3 2>/dev/null
check "GitOps repo has Tekton bump commit" bash -c "git ls-remote http://$GITEA_USER:$GITEA_PW@127.0.0.1:13000/$GITEA_USER/sf-infra.git main >/dev/null &&
  curl -fsS -u '$GITEA_USER:$GITEA_PW' 'http://127.0.0.1:13000/api/v1/repos/$GITEA_USER/sf-infra/raw/gitops/apps/sample-app/overlays/prod/kustomization.yaml' | tee -a '$REPO_ROOT/.local/e2e-evidence.log' | grep -q 'newTag: \"$SHORT\"'"

kubectl -n argocd annotate application sample-app argocd.argoproj.io/refresh=hard --overwrite >/dev/null
deployed() {
  local img h; img="$(kubectl -n sample-app get deploy sample-app -o jsonpath='{.spec.template.spec.containers[0].image}')"
  h="$(kubectl -n argocd get application sample-app -o jsonpath='{.status.health.status}')"
  log "deployment image=$img argo-health=$h"
  [[ "$img" == "registry.e2e.svc:5000/$GITEA_USER/sample-app:$SHORT" && "$h" == Healthy ]]
}
check "Argo CD rolled out new image and app is Healthy" wait_soft 600 "argo rollout" deployed

serve() {
  pf sample-app sample-app 18082:80 & local pf=$!
  sleep 5; local body; body="$(curl -fsS http://127.0.0.1:18082/)"; kill $pf 2>/dev/null
  log "app says: $body"; [[ "$body" == *"deployed by Tekton + Argo CD"* ]]
}
check "new build serving traffic" serve
kill $PF 2>/dev/null

echo
log "E2E RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
