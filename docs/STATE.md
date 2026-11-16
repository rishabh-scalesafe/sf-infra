# Where state and secrets live ("safest place")

| What | Where now | Recommended production location |
|---|---|---|
| Terraform state (has the k3s join token) | `terraform/envs/<cloud>/terraform.tfstate`, local and gitignored | Encrypted remote backend with locking. Pick **one** home cloud for state: Azure Storage (`use_azuread_auth`, versioning, soft delete), S3 (`use_lockfile`, SSE-KMS, versioning), or GCS (versioning, CMEK). |
| kubeconfig / SSH keys | `.local/` (gitignored) | Password manager or Key Vault. Use short-lived access later (Tailscale or a bastion). |
| GHCR / GitHub tokens | Env vars, then K8s Secrets in `ci` | Fine-grained PAT, or better a GitHub App, held in an External Secrets backend |
| Argo CD admin password | `argocd-initial-admin-secret` | Rotate (`argocd account update-password`), delete the initial secret, then switch to SSO |

## Create the Azure remote state backend (one time)

```bash
az group create -n scalesafe-tfstate-rg -l centralindia
az storage account create -n scalesafetfstate -g scalesafe-tfstate-rg -l centralindia \
  --sku Standard_ZRS --min-tls-version TLS1_2 --allow-blob-public-access false \
  --allow-shared-key-access false
az storage account blob-service-properties update -n scalesafetfstate -g scalesafe-tfstate-rg \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30
az storage container create -n tfstate --account-name scalesafetfstate --auth-mode login
az role assignment create --role "Storage Blob Data Contributor" --assignee <your-user-or-sp> \
  --scope $(az storage account show -n scalesafetfstate -g scalesafe-tfstate-rg --query id -o tsv)
```

Then uncomment the `backend "azurerm"` block in `terraform/envs/*/main.tf` and run `terraform init -migrate-state`.

The storage account name must be globally unique. Change `scalesafetfstate` if it is already taken.
