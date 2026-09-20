variable "azure_region" {
  description = "Azure region to deploy into. Choose a region where all required services (Container Apps, Policy initiatives, Key Vault Premium/HSM) are available and that fits the org's data-residency requirements."
  type        = string
  default     = "northeurope"
}

variable "project_name" {
  description = "Short name used as a prefix for all resources, for cost allocation tagging and resource naming."
  type        = string
  default     = "compliance-cicd"
}

variable "environment" {
  description = "Deployment environment name (dev|staging|production). Kept separate per environment to isolate blast radius and RBAC scope."
  type        = string
  default     = "dev"
}

variable "vnet_cidr" {
  description = "CIDR block for the application virtual network."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (Application Gateway only — app replicas stay private behind an internal Container Apps environment)."
  type        = string
  default     = "10.42.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet delegated to the Container Apps environment. Must be at least /23 for a Consumption-only environment, larger if using Dedicated workload profiles."
  type        = string
  default     = "10.42.16.0/23"
}

variable "evidence_storage_account_name" {
  description = "Globally-unique Storage Account name for the compliance evidence store. Must be lowercase alphanumeric only, 3-24 characters, unique across all of Azure."
  type        = string
  default     = "compliancecicdevidence"
}

variable "evidence_retention_years" {
  description = "Immutability policy retention period, in years, for evidence blobs. HIPAA requires a 6-year minimum retention for compliance documentation; default exceeds that floor."
  type        = number
  default     = 7
}

variable "lock_evidence_immutability_policy" {
  description = "Whether to set the evidence container's immutability policy to Locked state (irreversible — cannot be shortened or removed for the retention period, not even by a subscription Owner). Leave false while validating the module in a sandbox; set true deliberately before any real production cutover, since this is a one-way door."
  type        = bool
  default     = false
}

variable "github_org" {
  description = "GitHub organization name, used to scope federated identity credential subjects so only workflows from this org can exchange a token for Azure access."
  type        = string
  default     = "MMuyideen"
}

variable "github_repo" {
  description = "GitHub repository name (org/repo), used in federated identity credential subject conditions. Azure AD federated credentials require an EXACT subject match — unlike AWS IAM's StringLike wildcard support, there is no wildcard here, which is why separate federated credentials exist per trigger type (push to main, pull_request, environment:production) below."
  type        = string
  default     = "MMuyideen/compliant-cicd-pipeline"
}

variable "container_image_placeholder" {
  description = "Placeholder image used only for initial Container App bootstrap; the pipeline overwrites this with the signed, versioned image digest on every deploy."
  type        = string
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
}

variable "app_container_port" {
  description = "Port the application container listens on. Must match src/index.js's PORT default (8080) since the container app has no PORT env var forcing it otherwise."
  type        = number
  default     = 8080
}

variable "container_cpu" {
  description = "vCPU allocated per Container App replica. Must be a valid Container Apps CPU/memory combination (e.g. 0.5 vCPU pairs with 1Gi memory)."
  type        = number
  default     = 0.25
}

variable "container_memory" {
  description = "Memory allocated per Container App replica, paired with container_cpu per valid Container Apps combinations."
  type        = string
  default     = "0.5Gi"
}

variable "min_replicas" {
  description = "Minimum steady-state replica count. Raise to 2+ for production availability."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replica count under autoscale."
  type        = number
  default     = 1
}

variable "enable_waf" {
  description = "Whether the Application Gateway uses the WAF_v2 SKU (higher fixed cost) versus Standard_v2. Set true for a PHI-handling production endpoint."
  type        = bool
  default     = false
}

variable "appgw_min_capacity" {
  description = "Minimum Application Gateway v2 scale units (autoscale_configuration). 0 lets the gateway scale to zero when idle; production should keep a floor of 1+ for availability."
  type        = number
  default     = 0
}

variable "appgw_max_capacity" {
  description = "Maximum Application Gateway v2 scale units (autoscale_configuration). Azure requires at least 2 here regardless of min_capacity."
  type        = number
  default     = 2
}

variable "key_vault_purge_protection_enabled" {
  description = "Whether the Key Vault has purge protection (irreversible once enabled — Azure never allows turning it back off). Required for a real compliance posture; leave false for dev/sandbox so the stack stays fully destroyable."
  type        = bool
  default     = false
}

variable "key_vault_sku_name" {
  description = "Key Vault SKU. 'premium' is required for HSM-backed keys (RSA-HSM); 'standard' is cheaper and pairs with software-protected keys."
  type        = string
  default     = "standard"
}

variable "key_vault_key_type" {
  description = "Key type for the evidence/ACR encryption key. RSA-HSM requires the Premium Key Vault SKU (key_vault_sku_name)."
  type        = string
  default     = "RSA"
}

variable "acr_sku" {
  description = "Container Registry SKU. Premium is required for customer-managed-key encryption (enabled automatically when this is 'Premium'); Basic is far cheaper but drops CMK support."
  type        = string
  default     = "Basic"
}

variable "storage_replication_type" {
  description = "Replication type for the evidence storage account. GRS gives cross-region durability; LRS is cheaper and single-region."
  type        = string
  default     = "LRS"
}

variable "log_analytics_retention_days" {
  description = "Log Analytics retention window for operational logs. The HIPAA-mandated multi-year retention is met independently via the evidence storage account's locked immutability policy, so this only controls how long ops/debug logs stay queryable."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common resource tags applied everywhere, used for cost allocation and compliance-scope identification."
  type        = map(string)
  default = {
    Project    = "compliance-ready-cicd-pipeline"
    Compliance = "hipaa-in-scope"
    ManagedBy  = "terraform"
  }
}

variable "appgw_cert_data" {
  description = "Optional base64-encoded PKCS#12 (.pfx) certificate data for the Application Gateway TLS listener. When empty, the local certs/app-tls.pfx file is used."
  type        = string
  sensitive   = true
  default     = ""
}

variable "appgw_cert_password" {
  description = "Password for the PKCS#12 certificate bundle"
  type        = string
  sensitive   = true
  default     = "MySecureCertPassword123!"
}
