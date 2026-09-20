# Running this Terraform locally

This module provisions the VNet, evidence store, Entra ID/OIDC federation,
Container Apps compute tier, and the Azure Policy + Activity Log compliance
witnesses described in `architecture.md`. It's meant to be planned and
reviewed locally before any real Azure subscription applies it — several
resources here (the evidence container's immutability policy in Locked
state, resource locks) are intentionally hard or impossible to undo, so
treat `apply` as a one-way door.

## Prerequisites

- Terraform >= 1.5.0
- An Azure subscription and credentials available to the `azurerm`/`azuread`
  providers (`az login`, a service principal with client secret, or
  workload identity federation)
- `az` CLI, useful for inspecting what got created
- Owner or User Access Administrator on the target subscription (needed to
  create Entra ID app registrations, federated identity credentials, and
  role assignments)

## Option A — `terraform plan` against a real Azure subscription (read-only check)

This is the recommended way to review the module without provisioning
anything billable:

```bash
cd infra-as-code
terraform init
az login
terraform plan -var="github_org=your-org" -var="github_repo=your-org/your-repo"
```

Review the plan output for: the custom `evidence_writer` role definition's
`data_actions` (no delete permission), the container immutability policy's
`locked` value (should be `false` until you're ready for the one-way door),
and the federated identity credential subjects on `azuread_application_federated_identity_credential.ci_deploy_production`
(scoped to `environment:production`, exact string match — no wildcards, see
`variables.tf`). Do not `apply` against a real subscription unless you
intend to pay for a NAT Gateway, an Application Gateway, Container Apps
replicas, and a Premium-tier Container Registry — see `cost-estimate.md`.

## Option B — Azurite (safe to `apply`, nothing leaves your machine)

Azurite emulates Azure Blob/Queue/Table Storage locally, which is enough to
validate the evidence-store resource shape (storage account, container,
lifecycle policy HCL syntax) — but it does **not** emulate Container Apps,
Entra ID app registrations/federated credentials, Application Gateway, Key
Vault, or Azure Policy. Those are genuinely cloud-only resources; there is
no equivalent of AWS's LocalStack that covers this stack end-to-end on
Azure. Treat Azurite as useful for the Storage sub-resources only, and rely
on `terraform validate` + a real-subscription `plan` (Option A) as the
primary way to catch errors in the rest of the module.

```bash
npm install -g azurite
mkdir -p ./azurite-data
azurite --silent --location ./azurite-data --debug ./azurite-data/debug.log &

# Point a throwaway storage resource at Azurite's well-known emulator
# connection string instead of a real storage account. This validates HCL
# shape for blob_properties/lifecycle rules only — keep it in a separate,
# gitignored file, never commit it.
cat > azurite.tf <<'EOF'
# LOCAL DEV ONLY — do not commit. Azurite's default well-known account
# ("devstoreaccount1") and key, documented publicly by Microsoft.
variable "azurite_connection_string" {
  default = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;"
}
EOF

terraform init
terraform validate
```

Stop Azurite (`kill %1` or `docker stop` if run via the `mcr.microsoft.com/azure-storage/azurite` container image) and remove `azurite.tf` before applying against real Azure.

## Applying against a real Azure subscription

Only do this in a sandbox/dev subscription first.

```bash
terraform init
terraform apply \
  -var="github_org=your-org" \
  -var="github_repo=your-org/your-repo" \
  -var="evidence_storage_account_name=yourorgcompliancecicdevidence"
```

Notes:

- The Key Vault name includes the first eight characters of the subscription ID
  so it remains globally unique and does not collide with a soft-deleted vault
  from an earlier deployment. The generated name is
  `compliance-kv-9ef1d8ba` for the subscription used in the failed apply.
- Application Gateway WAF is configured through a dedicated WAF policy, as
  required by current Azure API versions; the retired inline
  `waf_configuration` block is not used.
- `evidence_storage_account_name` must be globally unique across all of
  Azure, lowercase alphanumeric only, 3-24 characters — the default will
  collide across subscriptions.
- Setting `lock_evidence_immutability_policy = true` means the evidence
  container **cannot have its retention shortened or removed** until every
  blob's retention period expires, not even by a subscription Owner.
  `terraform destroy` will fail on this container by design once locked.
  Budget for that before applying to a long-lived subscription — leave it
  `false` while validating the module, and only flip it deliberately.
- `github_repo` must exactly match `org/repo` — it's used verbatim in every
  federated identity credential's `subject`, so a mismatch means GitHub
  Actions simply cannot exchange its OIDC token for an Azure access token
  (fails closed, which is the intent). Remember federated credential
  subjects require an exact match, not a prefix or wildcard.
- The `HIPAA HITRUST 9.2` built-in Policy initiative referenced via
  `data "azurerm_policy_set_definition"` is available in every Azure
  tenant, but assigning it requires `Microsoft.Authorization/policyAssignments/write`
  at the resource-group scope — confirm the identity running `apply` has
  that permission before planning around it.

## Validating the plan without any credentials

```bash
terraform init -backend=false
terraform validate
```

`validate` catches syntax/type errors without any credentials. A full
`terraform plan` still needs valid (even if throwaway/sandbox) Azure
credentials because of the `data "azurerm_client_config" "current"` lookup
and the `data "azurerm_policy_set_definition"` lookup against the tenant's
available built-in initiatives.
