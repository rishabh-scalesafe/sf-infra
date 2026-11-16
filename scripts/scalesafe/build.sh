#!/usr/bin/env bash
# Build + push every ScaleSafe image for one commit with the standard Tekton pipeline, and bump the
# image tags in the GitOps repo (Argo CD then deploys). Runs N builds at a time.
#
#   scripts/scalesafe/build.sh <platform-git-rev> [site-git-rev]
#
# Env: PLATFORM_URL, SITE_URL (git URLs the cluster can clone), IMAGE_PREFIX (e.g. ghcr.io/<org>),
#      GITOPS_URL, GITOPS_PATH, INSECURE_REGISTRY (true only for an in-cluster test registry),
#      PARALLEL (default 2), ONLY (space-separated subset of images)
source "$(dirname "$0")/../lib/common.sh"
set +e

PLATFORM_REV="${1:?platform git revision}"
SITE_REV="${2:-main}"
: "${PLATFORM_URL:?}" "${SITE_URL:?}" "${IMAGE_PREFIX:?}" "${GITOPS_URL:?}"
GITOPS_PATH="${GITOPS_PATH:-gitops/apps/scalesafe/overlays/dev}"
INSECURE_REGISTRY="${INSECURE_REGISTRY:-false}"
PARALLEL="${PARALLEL:-2}"

# image | repo | dockerfile (context = repo root)
TARGETS="orchestrator|platform|services/orchestrator/Dockerfile
client-service|platform|services/client-service/Dockerfile
kyc-service|platform|services/kyc-service/Dockerfile
investor-service|platform|services/investor-service/Dockerfile
verification-service|platform|services/verification-service/Dockerfile
esign-service|platform|services/esign-service/Dockerfile
app|platform|web/app/Dockerfile
admin|platform|web/admin/Dockerfile
site|site|Dockerfile"

start_run() { # image repo dockerfile -> prints PipelineRun name
  local img="$1" repo="$2" df="$3" url rev
  if [[ $repo == platform ]]; then url=$PLATFORM_URL; rev=$PLATFORM_REV; else url=$SITE_URL; rev=$SITE_REV; fi
  kubectl create -o jsonpath='{.metadata.name}' -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: scalesafe-$img-
  namespace: ci
  labels: {scalesafe.io/app: scalesafe, scalesafe.io/image: $img}
spec:
  pipelineRef: {name: build-push-deploy}
  taskRunTemplate: {serviceAccountName: tekton-ci}
  timeouts: {pipeline: 45m}
  params:
    - {name: repo-url, value: "$url"}
    - {name: revision, value: "$rev"}
    - {name: image, value: "$IMAGE_PREFIX/scalesafe-$img"}
    - {name: dockerfile, value: "$df"}
    - {name: insecure-registry, value: "$INSECURE_REGISTRY"}
    - {name: gitops-repo-url, value: "$GITOPS_URL"}
    - {name: gitops-path, value: "$GITOPS_PATH"}
  workspaces:
    - name: source
      volumeClaimTemplate: {spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 2Gi}}}}
    - name: git-credentials
      secret: {secretName: git-credentials}
    - name: dockerconfig
      secret: {secretName: ghcr-push, items: [{key: .dockerconfigjson, path: config.json}]}
EOF
}

status() { kubectl -n ci get pipelinerun "$1" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null; }

declare -A RUN
queue=()
while IFS='|' read -r img repo df; do
  [[ -n "${ONLY:-}" && " $ONLY " != *" $img "* ]] && continue
  queue+=("$img|$repo|$df")
done <<< "$TARGETS"

active=(); ok=(); failed=()
while (( ${#queue[@]} > 0 || ${#active[@]} > 0 )); do
  while (( ${#active[@]} < PARALLEL && ${#queue[@]} > 0 )); do
    IFS='|' read -r img repo df <<< "${queue[0]}"; queue=("${queue[@]:1}")
    pr="$(retry 3 start_run "$img" "$repo" "$df")" || { failed+=("$img(create)"); continue; }
    RUN[$img]=$pr; active+=("$img"); log "started $img -> $pr"
  done
  sleep 20
  still=()
  for img in "${active[@]}"; do
    st="$(status "${RUN[$img]}")"
    case "$st" in
      True)  ok+=("$img");     log "DONE  $img (${RUN[$img]})" ;;
      False) failed+=("$img"); warn "FAIL  $img (${RUN[$img]})"
             kubectl -n ci logs -l "tekton.dev/pipelineRun=${RUN[$img]}" --all-containers --tail=25 >&2 ;;
      *)     still+=("$img") ;;
    esac
  done
  active=("${still[@]}")
done

log "built: ${ok[*]:-none}"
[[ ${#failed[@]} -eq 0 ]] || { warn "failed: ${failed[*]}"; exit 1; }
