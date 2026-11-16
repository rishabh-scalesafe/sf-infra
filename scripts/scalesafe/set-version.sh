#!/usr/bin/env bash
# Promote / roll back ScaleSafe WITHOUT rebuilding: re-pin already-built, immutable image tags in the
# GitOps repo (one commit), and Argo CD rolls the cluster to exactly those artifacts.
#
#   GITOPS_PUSH_URL=<git url with credentials> scripts/scalesafe/set-version.sh <platform-tag> [site-tag]
#
# Why: rebuilding an old commit to "downgrade" is slow (~10 min for 9 images) and does NOT reproduce the
# artifact that ran before (base images and `apk upgrade` move on). Rolling back = pointing Git at the
# old tag. Every tag must already exist in the registry; REGISTRY_CHECK_URL lets the script verify that.
source "$(dirname "$0")/../lib/common.sh"
PTAG="${1:?platform image tag (short sha)}"
STAG="${2:-}"
: "${GITOPS_PUSH_URL:?}"
GITOPS_PATH="${GITOPS_PATH:-gitops/apps/scalesafe/overlays/dev}"
PLATFORM_IMAGES="orchestrator client-service kyc-service investor-service verification-service esign-service app admin"

# Optional: refuse to pin tags the registry does not have (e.g. REGISTRY_CHECK_URL=http://127.0.0.1:15000/v2/scalesafe)
if [[ -n "${REGISTRY_CHECK_URL:-}" ]]; then
  for img in $PLATFORM_IMAGES ${STAG:+site}; do
    tag="$PTAG"; [[ $img == site ]] && tag="$STAG"
    curl -fsS "$REGISTRY_CHECK_URL/scalesafe-$img/tags/list" | grep -q "\"$tag\"" ||
      die "image scalesafe-$img:$tag not in registry - build it first (scripts/scalesafe/build.sh)"
  done
  log "all images present in registry"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git -c core.autocrlf=false clone -q --depth 5 "$GITOPS_PUSH_URL" "$WORK/repo"
git -C "$WORK/repo" config core.autocrlf false
K="$WORK/repo/$GITOPS_PATH/kustomization.yaml"
python - "$(native_path "$K")" "$PTAG" "$STAG" $PLATFORM_IMAGES <<'PY'
import re, sys
path, ptag, stag, *imgs = sys.argv[1:]
lines = open(path, encoding="utf-8").read().split("\n")
want = {f"scalesafe-{i}": ptag for i in imgs}
if stag:
    want["scalesafe-site"] = stag
cur = None
for n, line in enumerate(lines):
    m = re.search(r"newName:\s*\S*/(scalesafe-[a-z-]+)\s*$", line)
    if m:
        cur = m.group(1)
        continue
    if cur and re.match(r"\s*newTag:", line):
        if cur in want:
            lines[n] = re.sub(r"newTag:.*", f'newTag: "{want[cur]}"', line)
        cur = None
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
PY
cd "$WORK/repo"
if git diff --quiet; then log "already at platform=$PTAG site=${STAG:-unchanged}"; exit 0; fi
git -c user.name=scalesafe-release -c user.email=release@users.noreply.github.com \
  commit -qam "release: scalesafe platform=$PTAG${STAG:+ site=$STAG} (re-pin, no rebuild)"
retry 3 git push -q origin HEAD
log "pushed $(git rev-parse --short HEAD): platform=$PTAG${STAG:+ site=$STAG}"
