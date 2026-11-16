#!/usr/bin/env bash
# Small k3s test cluster on Azure using plain `az vm create` (1 server + N agents).
# Uses the SAME cloud-init as the Terraform modules, so it exercises the real bootstrap.
#
#   scripts/azure-quicktest.sh            # create (idempotent-ish: skips what exists)
#   scripts/azure-quicktest.sh destroy    # delete the whole resource group
#
# Env overrides: RG, LOC, CLUSTER, SIZE, AGENTS, ADMIN_CIDR, WEB_CIDR, AUTO_SHUTDOWN_UTC
source "$(dirname "$0")/lib/common.sh"

RG="${RG:-sf-infra-qt-rg}"
LOC="${LOC:-centralindia}"
CLUSTER="${CLUSTER:-sfqt}"
# Tried in order until one has capacity (B2s is often capacity-restricted in centralindia).
SIZES="${SIZES:-Standard_B2as_v2 Standard_B2s_v2 Standard_D2as_v5 Standard_D2s_v5 Standard_B2s}"
AGENTS="${AGENTS:-1}"
ADMIN_USER="scalesafe"
ADMIN_CIDR="${ADMIN_CIDR:-$(curl -fsS https://api.ipify.org)/32}"
WEB_CIDR="${WEB_CIDR:-$ADMIN_CIDR}"          # test cluster: web only from your IP too
AUTO_SHUTDOWN_UTC="${AUTO_SHUTDOWN_UTC:-0330}" # 09:00 IST safety net (VMs deallocate)
STATE="$REPO_ROOT/.local/azure-quicktest"
mkdir -p "$STATE"

if [[ "${1:-}" == "destroy" ]]; then
  log "Deleting resource group $RG (async)..."
  az group delete -n "$RG" --yes --no-wait
  log "Delete requested. Check: az group show -n $RG"
  exit 0
fi

# ---------------------------------------------------------------- secrets (local only, gitignored)
[[ -f "$STATE/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N "" -C "scalesafe-quicktest" -f "$STATE/id_ed25519"
[[ -f "$STATE/k3s-token" ]] || { random_token > "$STATE/k3s-token"; chmod 600 "$STATE/k3s-token"; }
TOKEN="$(tr -d '\r\n' < "$STATE/k3s-token")"
PUBKEY_FILE="$(native_path "$STATE/id_ed25519.pub")"

log "RG=$RG LOC=$LOC SIZES=[$SIZES] AGENTS=$AGENTS ADMIN_CIDR=$ADMIN_CIDR"

# ---------------------------------------------------------------- network
az group create -n "$RG" -l "$LOC" --tags project=scalesafe purpose=quicktest -o none
az network nsg create -g "$RG" -n "$CLUSTER-nsg" -o none
az network nsg rule create -g "$RG" --nsg-name "$CLUSTER-nsg" -n ssh-admin --priority 100 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes "$ADMIN_CIDR" --destination-port-ranges 22 -o none
az network nsg rule create -g "$RG" --nsg-name "$CLUSTER-nsg" -n kubeapi-admin --priority 110 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes "$ADMIN_CIDR" --destination-port-ranges 6443 -o none
az network nsg rule create -g "$RG" --nsg-name "$CLUSTER-nsg" -n web --priority 120 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes "$WEB_CIDR" --destination-port-ranges 80 443 -o none
az network vnet create -g "$RG" -n "$CLUSTER-vnet" --address-prefix 10.10.0.0/16 \
  --subnet-name nodes --subnet-prefix 10.10.1.0/24 --network-security-group "$CLUSTER-nsg" -o none

pip() { # create static Standard public IP, echo address
  az network public-ip create -g "$RG" -n "$1" --sku Standard --allocation-method Static -o none
  az network public-ip show -g "$RG" -n "$1" --query ipAddress -o tsv | tr -d '\r'
}

create_vm() { # create_vm <name> <pip-name> <cloud-init-file> [private-ip]
  local name="$1" pipname="$2" ci="$3" privip="${4:-}"
  if az vm show -g "$RG" -n "$name" -o none 2>/dev/null; then log "VM $name exists, skipping"; return; fi
  local extra=()
  [[ -n "$privip" ]] && extra+=(--private-ip-address "$privip")
  local size
  for size in $SIZES; do
    log "Creating VM $name (size $size) ..."
    if _az_vm_create "$name" "$pipname" "$ci" "$size" "${extra[@]}"; then
      az vm auto-shutdown -g "$RG" -n "$name" --time "$AUTO_SHUTDOWN_UTC" -o none || warn "auto-shutdown not set on $name"
      return 0
    fi
    warn "size $size failed for $name (capacity/quota?), cleaning up and trying next"
    az vm delete -g "$RG" -n "$name" --yes -o none 2>/dev/null || true
    az network nic delete -g "$RG" -n "${name}VMNic" -o none 2>/dev/null || true
  done
  die "could not create $name with any of: $SIZES"
}

_az_vm_create() { # _az_vm_create <name> <pip> <cloud-init> <size> [extra args]
  local name="$1" pipname="$2" ci="$3" size="$4"; shift 4
  az vm create -g "$RG" -n "$name" \
    --image Canonical:ubuntu-24_04-lts:server:latest --size "$size" \
    --admin-username "$ADMIN_USER" --ssh-key-values "$PUBKEY_FILE" \
    --authentication-type ssh \
    --vnet-name "$CLUSTER-vnet" --subnet nodes --nsg "" --public-ip-address "$pipname" \
    --os-disk-size-gb 64 --storage-sku StandardSSD_LRS \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --custom-data "$(native_path "$ci")" \
    --tags project=scalesafe purpose=quicktest "cluster=$CLUSTER" \
    "$@" -o none 2> >(grep -E "ERROR|Code:|Message:" >&2 || true)
}

# ---------------------------------------------------------------- server
SERVER_PRIV=10.10.1.10
SERVER_IP="$(pip "$CLUSTER-server-pip")"
log "Server public IP: $SERVER_IP"
render_cloudinit server "$STATE/server.cloudinit" azure "$CLUSTER" "$TOKEN" "" "$SERVER_IP"
create_vm "$CLUSTER-server-0" "$CLUSTER-server-pip" "$STATE/server.cloudinit" "$SERVER_PRIV"

# ---------------------------------------------------------------- agents
render_cloudinit agent "$STATE/agent.cloudinit" azure "$CLUSTER" "$TOKEN" "https://$SERVER_PRIV:6443"
for ((i = 0; i < AGENTS; i++)); do
  pip "$CLUSTER-agent-$i-pip" >/dev/null
  create_vm "$CLUSTER-agent-$i" "$CLUSTER-agent-$i-pip" "$STATE/agent.cloudinit"
done

# ---------------------------------------------------------------- kubeconfig
SSH=(ssh -i "$STATE/id_ed25519" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=\"$STATE/known_hosts\"" -o ConnectTimeout=10 "$ADMIN_USER@$SERVER_IP")
wait_for 900 "cloud-init + k3s on server" "${SSH[@]}" "test -f /var/lib/scalesafe-bootstrap-done && sudo test -f /etc/rancher/k3s/k3s.yaml"
"${SSH[@]}" "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s#https://127.0.0.1:6443#https://$SERVER_IP:6443#; s#: default\$#: $CLUSTER#" > "$STATE/kubeconfig"
chmod 600 "$STATE/kubeconfig"
export KUBECONFIG="$STATE/kubeconfig"

expected=$((AGENTS + 1))
nodes_ready() { [[ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge "$expected" ]]; }
wait_for 900 "$expected nodes Ready" nodes_ready
kubectl get nodes -o wide

cat <<EOF

Cluster is up.
  export KUBECONFIG="$STATE/kubeconfig"
  ssh -i "$STATE/id_ed25519" $ADMIN_USER@$SERVER_IP
Next: scripts/bootstrap-platform.sh   (Argo CD + Tekton)
Teardown: scripts/azure-quicktest.sh destroy
EOF
