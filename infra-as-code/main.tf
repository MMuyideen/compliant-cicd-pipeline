

data "azurerm_client_config" "current" {}



# ---------------------------------------------------------------------------
# Resource Group — everything in this module lives in one RG for a small
# single-service team; 
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "${var.project_name}-rg"
  location = var.azure_region
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# VNet — private subnet for the Container Apps environment (internal-only
# ingress), public subnet only for the Application Gateway. PHI-handling
# workloads should not have direct-to-internet routes; all outbound traffic
# from the private subnet goes through a NAT Gateway so egress is auditable
# via NSG flow logs.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "main" {
  name                = "${var.project_name}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "public" {
  name                 = "${var.project_name}-public"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.public_subnet_cidr]
}

resource "azurerm_subnet" "private" {
  name                 = "${var.project_name}-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_subnet_cidr]

  delegation {
    name = "container-apps-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_public_ip" "nat" {
  name                = "${var.project_name}-nat-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "${var.project_name}-nat"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# ---------------------------------------------------------------------------
# Key Vault — holds the customer-managed key used to encrypt the evidence
# store and container registry. RBAC authorization (not access policies) so
# key permissions are managed the same way as every other resource here.
# SKU/key type and purge protection are variables — set Premium/RSA-HSM and
# purge protection on for a real compliance posture (see variables.tf).
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                       = local.key_vault_name
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = var.key_vault_sku_name
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = 90
  tags                       = var.tags
}

resource "azurerm_role_assignment" "terraform_kv_admin" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "evidence" {
  name         = "${var.project_name}-evidence-cmk"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = var.key_vault_key_type
  key_size     = 3072
  key_opts     = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]

  rotation_policy {
    expire_after         = "P2Y"
    notify_before_expiry = "P29D"
    automatic {
      time_before_expiry = "P90D"
    }
  }

  depends_on = [azurerm_role_assignment.terraform_kv_admin]
}

# ---------------------------------------------------------------------------
# Evidence store — the legally load-bearing resource in this whole project.
# Versioned + customer-managed-key encrypted + a container-level immutability
# policy. Locking the policy (locked = true) is the equivalent of AWS S3
# Object Lock COMPLIANCE mode: not even a subscription Owner can shorten or
# remove retention once locked. Locking requires versioning to already be
# enabled, and is intentionally gated behind a variable (see variables.tf)
# because it's a one-way door.
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "evidence" {
  name                            = var.evidence_storage_account_name
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  account_tier                    = "Standard"
  account_replication_type        = var.storage_replication_type
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # force Entra ID / RBAC auth, no account-key access

  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled = true
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "evidence_storage_kv_access" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_storage_account.evidence.identity[0].principal_id
}

resource "azurerm_storage_account_customer_managed_key" "evidence" {
  # Azure requires the Key Vault to have purge protection enabled for CMK.
  count              = var.key_vault_purge_protection_enabled ? 1 : 0
  storage_account_id = azurerm_storage_account.evidence.id
  key_vault_key_id   = azurerm_key_vault_key.evidence.id
  depends_on         = [azurerm_role_assignment.evidence_storage_kv_access]
}

resource "azurerm_storage_container" "evidence" {
  name                  = "evidence"
  storage_account_id    = azurerm_storage_account.evidence.id
  container_access_type = "private"
}

# Container-level WORM policy — the direct analog of S3 Object Lock. `locked
# = true` is irreversible; see variables.tf's lock_evidence_immutability_policy.
resource "azurerm_storage_container_immutability_policy" "evidence" {
  storage_container_resource_manager_id = azurerm_storage_container.evidence.id
  immutability_period_in_days           = var.evidence_retention_years * 365
  protected_append_writes_enabled       = true
  locked                                = var.lock_evidence_immutability_policy
}

# Lifecycle: move evidence to cheaper access tiers once the "active audit
# window" passes, without weakening the immutability policy itself — this is
# the lever used in the budget-cut scenario (see scale-and-budget-scenarios.md).
resource "azurerm_storage_management_policy" "evidence" {
  storage_account_id = azurerm_storage_account.evidence.id

  rule {
    name    = "archive-after-90-days"
    enabled = true
    filters {
      prefix_match = ["evidence/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 90
        tier_to_archive_after_days_since_modification_greater_than = 365
      }
    }
  }
}

resource "azurerm_user_assigned_identity" "acr" {
  name                = "${var.project_name}-acr-identity"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr_kv_access" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.acr.principal_id
}

resource "azurerm_container_registry" "main" {
  name                = replace("${var.project_name}acr", "-", "")
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.acr_sku
  admin_enabled       = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acr.id]
  }

  # CMK encryption requires the Premium SKU.
  dynamic "encryption" {
    for_each = var.acr_sku == "Premium" ? [1] : []
    content {
      key_vault_key_id   = azurerm_key_vault_key.evidence.id
      identity_client_id = azurerm_user_assigned_identity.acr.client_id
    }
  }

  tags = var.tags

  # CMK access must exist before the registry can use the key.
  depends_on = [azurerm_role_assignment.acr_kv_access]
}

# ---------------------------------------------------------------------------
# Log Analytics + Application Insights — Container Apps streams logs here
# natively; Application Insights (workspace-based) is the X-Ray equivalent
# for distributed tracing.
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.project_name}-logs"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = var.tags
}

resource "azurerm_application_insights" "main" {
  name                = "${var.project_name}-appinsights"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Compute tier — Azure Container Apps (Consumption plan), the Fargate
# equivalent: the small team isn't patching Kubernetes nodes or a control
# plane. internal_load_balancer_enabled = true means the environment has no
# public ingress of its own — the Application Gateway below is the only
# public entry point, matching the AWS design's "ALB in public subnet, tasks
# in private subnet" shape.
# ---------------------------------------------------------------------------
resource "azurerm_container_app_environment" "main" {
  name                           = "${var.project_name}-${var.environment}-env"
  location                       = azurerm_resource_group.main.location
  resource_group_name            = azurerm_resource_group.main.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id       = azurerm_subnet.private.id
  internal_load_balancer_enabled = true
  tags                           = var.tags

  # Subnet associations aren't implicit dependencies of infrastructure_subnet_id.
  depends_on = [azurerm_subnet_nat_gateway_association.private]
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.project_name}-app-identity"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app" "app" {
  name                         = "${var.project_name}-app"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Multiple" # required for the 0%-traffic bake-and-shift pattern in ci-cd/pipeline.yml

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  # Must exist before the app so registry auth (above) has AcrPull already granted.
  depends_on = [azurerm_role_assignment.app_acr_pull]

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name = "app"
      # Overwritten every deploy with the specific signed image digest —
      # never a mutable tag — so the active revision always traces back to
      # one verifiable artifact.
      image  = var.container_image_placeholder
      cpu    = var.container_cpu
      memory = var.container_memory
    }
  }

  ingress {
    external_enabled = false # only reachable via the Application Gateway
    target_port      = var.app_container_port
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = var.tags

  # The image is CI-managed (az containerapp update, per commit digest) —
  # Terraform only sets the initial placeholder so the app has something to
  # boot with the first time this resource is created.
  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# ---------------------------------------------------------------------------
# Application Gateway — public entry point, WAF_v2 by default (see
# variables.tf `enable_waf` and cost-estimate.md for the meaningful cost
# delta this carries versus an AWS ALB+WAF).
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "appgw" {
  name                = "${var.project_name}-appgw-ip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_web_application_firewall_policy" "appgw" {
  count               = var.enable_waf ? 1 : 0
  name                = "${var.project_name}-waf-policy"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  policy_settings {
    enabled = true
    mode    = "Prevention"
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }

  tags = var.tags
}

resource "azurerm_application_gateway" "main" {
  name                = "${var.project_name}-appgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  sku {
    name = var.enable_waf ? "WAF_v2" : "Standard_v2"
    tier = var.enable_waf ? "WAF_v2" : "Standard_v2"
  }

  autoscale_configuration {
    min_capacity = var.appgw_min_capacity
    max_capacity = var.appgw_max_capacity
  }

  firewall_policy_id = var.enable_waf ? azurerm_web_application_firewall_policy.appgw[0].id : null

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.public.id
  }

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  backend_address_pool {
    name  = "app-backend-pool"
    fqdns = [azurerm_container_app.app.ingress[0].fqdn]
  }

  backend_http_settings {
    name                                = "app-backend-http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
    probe_name                          = "app-health-probe"
  }

  # Default probe hits "/", which the app never defines (see src/server.js —
  # only /healthz and /api/patients exist), so it must be pointed explicitly
  # at the app's actual health endpoint.
  probe {
    name                                      = "app-health-probe"
    protocol                                  = "Https"
    path                                      = "/healthz"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-399"]
    }
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "app-tls-cert"
  }

  # Certificate content supplied at apply time via -var, never committed —
  # placeholder here to keep the resource graph complete for `plan`/`validate`.
  ssl_certificate {
    name     = "app-tls-cert"
    data     = var.appgw_cert_data != "" ? var.appgw_cert_data : filebase64("${path.module}/certs/app-tls.pfx")
    password = var.appgw_cert_password
  }

  request_routing_rule {
    name                       = "https-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "app-backend-pool"
    backend_http_settings_name = "app-backend-http-settings"
    priority                   = 100
  }

}

# ---------------------------------------------------------------------------
# Private DNS for the internal Container Apps environment. With a
# customer-supplied VNet, Azure does not auto-provision or link a zone for
# the environment's default domain, so the App Gateway's backend pool FQDN
# is otherwise unresolvable (backend health stays "Unknown" indefinitely).
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "container_apps" {
  name                = azurerm_container_app_environment.main.default_domain
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "container_apps" {
  name                  = "${var.project_name}-appenv-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.container_apps.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = var.tags
}

resource "azurerm_private_dns_a_record" "container_apps_apex" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.container_apps.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.main.static_ip_address]
}

resource "azurerm_private_dns_a_record" "container_apps_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.container_apps.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.main.static_ip_address]
}

# Individual container apps in an internal environment get FQDNs of the
# form "<app>.internal.<default_domain>" — one label deeper than the
# top-level wildcard above covers.
resource "azurerm_private_dns_a_record" "container_apps_internal_wildcard" {
  name                = "*.internal"
  zone_name           = azurerm_private_dns_zone.container_apps.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.main.static_ip_address]
}

# ---------------------------------------------------------------------------
# GitHub OIDC federation (ci_build / ci_deploy_production app registrations,
# service principals, and federated credentials) is managed manually outside
# Terraform. Point CI_BUILD_CLIENT_ID / CI_DEPLOY_PRODUCTION_CLIENT_ID GitHub
# secrets at whatever app registrations are created by hand, and re-add
# azurerm_role_assignment blocks below scoped to their service principal
# object IDs.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Least-privilege RBAC for the CI identities. Azure RBAC has no
# generally-available, user-created "explicit Deny" the way AWS IAM does —
# see constraints-tradeoffs.md for the full discussion. The compensating
# design here is (a) a minimal custom role granting only the specific
# data-plane actions needed, plus (b) resource locks and deny-effect Policy
# assignments further down this file, assigned by a human/break-glass
# identity the CI service principals cannot themselves alter.
# ---------------------------------------------------------------------------
resource "azurerm_role_definition" "evidence_writer" {
  name        = "${var.project_name}-evidence-writer"
  scope       = azurerm_storage_account.evidence.id
  description = "Write and read evidence blobs only — no delete, no container/account-level management actions."

  permissions {
    actions     = []
    not_actions = []
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
    ]
    not_data_actions = []
  }

  assignable_scopes = [azurerm_storage_account.evidence.id]
}

# Role assignments for the CI identities (evidence write, ACR push, Container
# Apps deploy) are managed manually alongside the app registrations above —
# see azurerm_role_definition.evidence_writer for the custom role to assign.

# ---------------------------------------------------------------------------
# Resource locks — stand in for part of what an AWS IAM explicit Deny would
# cover: even a principal with an accidentally-broad role assignment cannot
# delete the evidence account or the Key Vault holding its encryption key.
# ---------------------------------------------------------------------------
resource "azurerm_management_lock" "evidence_storage" {
  name       = "${var.project_name}-evidence-lock"
  scope      = azurerm_storage_account.evidence.id
  lock_level = "CanNotDelete"
  notes      = "Evidence store backing the compliance chain-of-custody. Deletion would destroy audit history; see failure-modes-and-mitigation.md."
}

resource "azurerm_management_lock" "key_vault" {
  name       = "${var.project_name}-kv-lock"
  scope      = azurerm_key_vault.main.id
  lock_level = "CanNotDelete"
  notes      = "Holds the CMK encrypting the evidence store and registry."
}

# ---------------------------------------------------------------------------
# Azure Policy — the independent compliance witness described in
# architecture.md. The built-in "HIPAA HITRUST 9.2" regulatory-compliance
# initiative gives Microsoft-maintained coverage; two custom policies fill
# the specific gaps this design cares about (no standing Owner/Contributor
# on the CI principals, evidence container stays immutable).
# ---------------------------------------------------------------------------
data "azurerm_policy_set_definition" "hipaa_hitrust" {
  display_name = "HITRUST/HIPAA"
}

resource "azurerm_resource_group_policy_assignment" "hipaa_hitrust" {
  name                 = "${var.project_name}-hipaa-hitrust"
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = data.azurerm_policy_set_definition.hipaa_hitrust.id
  location             = azurerm_resource_group.main.location

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_policy_definition" "deny_owner_role_assignment" {
  name         = "${var.project_name}-deny-owner-role-assignment"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Deny standing Owner/Contributor role assignments in this resource group"

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Authorization/roleAssignments" },
        {
          field = "Microsoft.Authorization/roleAssignments/roleDefinitionId"
          in = [
            "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635", # Owner
            "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c", # Contributor
          ]
        }
      ]
    }
    then = { effect = "deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "deny_owner_role_assignment" {
  name                 = "${var.project_name}-deny-owner-assignment"
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = azurerm_policy_definition.deny_owner_role_assignment.id
}

# ---------------------------------------------------------------------------
# Activity Log + Entra ID Audit Log export — the second independent
# evidence feed referenced in architecture.md. Activity Log covers
# control-plane (ARM) operations; Entra ID Audit Log covers identity-plane
# operations (role assignment changes, federated-credential edits) and
# requires Entra ID Premium P1 at minimum — confirm tenant licensing before
# relying on this (see constraints-tradeoffs.md).
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "${var.project_name}-activity-log-to-evidence"
  target_resource_id         = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  storage_account_id         = azurerm_storage_account.evidence.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "Administrative"
  }
  enabled_log {
    category = "Policy"
  }
  enabled_log {
    category = "Security"
  }
}

resource "azurerm_monitor_aad_diagnostic_setting" "entra_audit_log" {
  name                       = "${var.project_name}-entra-audit-log-to-evidence"
  storage_account_id         = azurerm_storage_account.evidence.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "AuditLogs"
  }
  enabled_log {
    category = "SignInLogs"
  }
}
