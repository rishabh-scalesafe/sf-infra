#!/usr/bin/env bash
# One command per cloud. Same flow everywhere:
#   scripts/deploy.sh <azure|aws|gcp> plan|apply|destroy
#   scripts/deploy.sh <azure|aws|gcp> kubeconfig      # fetch kubeconfig after apply
#   scripts/deploy.sh <azure|aws|gcp> platform        # Argo CD + Tekton onto that cluster
#   scripts/deploy.sh cloudflare plan|apply           # point DNS at the cluster
#
# Requires terraform/envs/<cloud>/terraform.tfvars (copy from terraform.tfvars.example).
source "$(dirname "$0")/lib/common.sh"

CLOUD="${1:?usage: $0 <azure|aws|gcp|cloudflare> <plan|apply|destroy|kubeconfig|platform>}"
ACTION="${2:?action required}"
ENV_DIR="$REPO_ROOT/terraform/envs/$CLOUD"
[[ -d "$ENV_DIR" ]] || die "unknown cloud: $CLOUD"
STATE="$REPO_ROOT/.local/$CLOUD"
mkdir -p "$STATE"

tf() { terraform -chdir="$ENV_DIR" "$@"; }

case "$ACTION" in
  plan|apply|destroy)
    [[ -f "$ENV_DIR/terraform.tfvars" ]] || die "create $ENV_DIR/terraform.tfvars from terraform.tfvars.example"
    tf init -input=false
    if [[ "$ACTION" == plan ]]; then tf plan -out="$(native_path "$STATE/tfplan")"
    elif [[ "$ACTION" == apply ]]; then
      if [[ -f "$STATE/tfplan" ]]; then tf apply "$(native_path "$STATE/tfplan")"; rm -f "$STATE/tfplan"
      else tf apply; fi
    else tf destroy; fi
    ;;
  kubeconfig)
    IP="$(tf output -raw server_public_ip)"
    USER_="$(tf output -raw ssh_user)"
    KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=\"$STATE/known_hosts\"" -o ConnectTimeout=10 "$USER_@$IP")
    wait_for 900 "k3s on $IP" "${SSH[@]}" "test -f /var/lib/scalesafe-bootstrap-done && sudo test -f /etc/rancher/k3s/k3s.yaml"
    "${SSH[@]}" "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s#https://127.0.0.1:6443#https://$IP:6443#; s#: default\$#: scalesafe-$CLOUD#" > "$STATE/kubeconfig"
    chmod 600 "$STATE/kubeconfig"
    log "export KUBECONFIG=$STATE/kubeconfig"
    ;;
  platform)
    KUBECONFIG="$STATE/kubeconfig" "$REPO_ROOT/scripts/bootstrap-platform.sh"
    ;;
  *) die "unknown action: $ACTION" ;;
esac
