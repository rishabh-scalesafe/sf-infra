#!/usr/bin/env bash
# One-time: replace placeholders with your real values (run before pushing to GitHub).
#
#   scripts/configure.sh <github-org> <gitops-repo-url> <domain>
#   scripts/configure.sh scalesafe https://github.com/scalesafe/sf-infra.git scalesafe.co.in
source "$(dirname "$0")/lib/common.sh"
cd "$REPO_ROOT"

[[ $# -eq 3 ]] || die "usage: $0 <github-org> <gitops-repo-url> <domain>"
ORG="$(echo "$1" | tr '[:upper:]' '[:lower:]')"   # GHCR paths must be lowercase
REPO="$2"
DOMAIN="$3"

mapfile -t files < <(grep -rlE '__GITHUB_ORG__|__GITOPS_REPO_URL__|__DOMAIN__' \
  --include='*.yaml' --include='*.yml' platform tekton gitops || true)
[[ ${#files[@]} -gt 0 ]] || { log "No placeholders left - already configured."; exit 0; }

for f in "${files[@]}"; do
  sed -i -e "s#__GITHUB_ORG__#${ORG}#g" -e "s#__GITOPS_REPO_URL__#${REPO}#g" -e "s#__DOMAIN__#${DOMAIN}#g" "$f"
  log "configured $f"
done
