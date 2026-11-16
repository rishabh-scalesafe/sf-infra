#!/usr/bin/env bash
# Mirror the committed history of local ScaleSafe repos into the test Gitea (stand-in for GitHub),
# so the cluster can clone any commit. Read-only on the source repos: it bare-clones them first.
#
#   PLATFORM_REPO=... SITE_REPO=... GITEA_URL=http://127.0.0.1:13000 scripts/scalesafe/push-sources.sh
source "$(dirname "$0")/../lib/common.sh"
: "${PLATFORM_REPO:?}" "${SITE_REPO:?}"
GITEA_URL="${GITEA_URL:-http://127.0.0.1:13000}"
GITEA_USER="${GITEA_USER:-scalesafe}"
GITEA_PW="${GITEA_PW:-$(tr -d '\r\n' < "$REPO_ROOT/.local/e2e-gitea-pw")}"
WORK="$REPO_ROOT/.local/src"
mkdir -p "$WORK"

push_repo() { # <local repo> <gitea repo name>
  local src="$1" name="$2" bare="$WORK/$2.git"
  rm -rf "$bare"
  git clone -q --bare --no-local "$src" "$bare"
  local remote="${GITEA_URL/http:\/\//http://$GITEA_USER:$GITEA_PW@}/$GITEA_USER/$name.git"
  retry 3 git -C "$bare" push -q --force "$remote" 'refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
  log "pushed $name: HEAD $(git -C "$bare" rev-parse --short HEAD) ($(git -C "$bare" rev-list --count HEAD) commits)"
}

push_repo "$PLATFORM_REPO" scalesafe-platform
push_repo "$SITE_REPO" scalesafe
