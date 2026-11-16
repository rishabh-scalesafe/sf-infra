#!/usr/bin/env bash
# Install the platform on ANY k3s/Kubernetes cluster (Azure, AWS, GCP, bare metal):
#   namespaces -> Tekton (pipelines, triggers, dashboard) -> Argo CD -> CI definitions.
# Uses exactly the kustomizations Argo CD later manages (platform/*, tekton/), so after
# `kubectl apply -f gitops/argocd/root.yaml` Argo CD simply adopts what is already there.
#
#   KUBECONFIG=... scripts/bootstrap-platform.sh
source "$(dirname "$0")/lib/common.sh"
cd "$REPO_ROOT"

kubectl version >/dev/null || die "kubectl cannot reach the cluster (check KUBECONFIG)"
log "Cluster: $(kubectl config current-context)"

# CRDs and their custom resources live in the same bundles: apply, wait for CRDs, re-apply.
apply_with_crds() {
  kubectl apply --server-side --force-conflicts -k "$1" || warn "first pass incomplete (CRDs registering) - retrying"
  retry 5 kubectl wait --for=condition=Established crd --all --timeout=120s >/dev/null
  retry 5 kubectl apply --server-side --force-conflicts -k "$1"
}

log "1/5 namespaces + guardrails"
retry 5 kubectl apply --server-side -k platform/namespaces

log "2/5 Tekton Pipelines $TEKTON_PIPELINES_VERSION, Triggers $TEKTON_TRIGGERS_VERSION, Dashboard $TEKTON_DASHBOARD_VERSION"
apply_with_crds platform/tekton
for d in tekton-pipelines-controller tekton-pipelines-webhook tekton-triggers-controller tekton-triggers-webhook tekton-dashboard; do
  retry 3 kubectl -n tekton-pipelines rollout status "deploy/$d" --timeout=600s
done
retry 3 kubectl -n tekton-pipelines rollout status deploy/tekton-triggers-core-interceptors --timeout=600s

log "3/5 Argo CD $ARGOCD_VERSION"
apply_with_crds platform/argocd
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-redis argocd-dex-server argocd-notifications-controller; do
  retry 3 kubectl -n argocd rollout status "deploy/$d" --timeout=600s
done
retry 3 kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

log "4/5 CI definitions (tasks, pipeline, triggers)"
# Webhook validation can lag a few seconds behind the deployment being Ready.
for i in 1 2 3 4 5 6; do
  if kubectl apply --server-side -k tekton; then break; fi
  [[ $i == 6 ]] && die "could not apply tekton/ definitions"
  warn "retrying in 10s ($i)"; sleep 10
done

log "5/5 Argo CD projects"
retry 5 kubectl apply --server-side -f gitops/argocd/projects/

cat <<EOF

Platform installed.
  Argo CD UI:   kubectl -n argocd port-forward svc/argocd-server 8080:80   -> http://localhost:8080
                user: admin  password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  Tekton UI:    kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097 -> http://localhost:9097
Next:
  scripts/create-ci-secrets.sh       (GHCR + GitHub credentials, webhook secret)
  kubectl apply -f gitops/argocd/root.yaml   (after the repo is on GitHub + scripts/configure.sh)
EOF
