# shellcheck shell=bash
# Shared helpers for ScaleSafe infra scripts. Works in Linux/macOS bash and Git Bash on Windows.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Azure CLI: call the bundled python directly on Windows to avoid cmd.exe quoting bugs.
az() {
  local winpy="/c/Program Files/Microsoft SDKs/Azure/CLI2/python.exe"
  if [[ -x "$winpy" ]]; then "$winpy" -IBm azure.cli "$@"; else command az "$@"; fi
}

# Terraform: prefer PATH, fall back to D:/tools on this workstation.
terraform() {
  if command -v terraform.exe >/dev/null 2>&1 || command -v terraform >/dev/null 2>&1; then
    command terraform "$@"
  elif [[ -x /d/tools/terraform.exe ]]; then /d/tools/terraform.exe "$@"
  else die "terraform not found"; fi
}

# Native path for tools that are Windows binaries (terraform.exe, az python).
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

random_token() { python - <<'PY' 2>/dev/null || openssl rand -hex 32
import secrets; print(secrets.token_hex(32))
PY
}

# render_cloudinit <role> <out-file> <cloud> <cluster> <token> [server_url] [tls_san...]
render_cloudinit() {
  local role="$1" out="$2" cloud="$3" cluster="$4" token="$5" server_url="${6:-}"; shift 6 || shift $#
  local sans="[" s
  for s in "$@"; do sans+="\"$s\","; done
  sans="${sans%,}]"
  local dir="$REPO_ROOT/scripts/render-cloudinit" st
  st="$(native_path "$(dirname "$out")/render-$role.tfstate")"
  terraform -chdir="$dir" init -input=false -no-color >/dev/null
  terraform -chdir="$dir" apply -input=false -auto-approve -no-color -state="$st" \
    -var "role=$role" -var "k3s_version=$K3S_VERSION" -var "k3s_token=$token" \
    -var "server_url=$server_url" -var "tls_sans=$sans" \
    -var "cloud=$cloud" -var "cluster_name=$cluster" >/dev/null
  terraform -chdir="$dir" output -state="$st" -raw rendered > "$out"
}

wait_for() { # wait_for <timeout-seconds> <description> <command...>
  local timeout="$1" desc="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for: $desc"
    sleep 10
  done
  log "ready: $desc ($((SECONDS - start))s)"
}

# retry <attempts> <command...>  - for flaky networks (mobile hotspots, API restarts)
retry() {
  local n="$1" i; shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    warn "attempt $i/$n failed: $*"; sleep $((i * 10))
  done
  return 1
}
