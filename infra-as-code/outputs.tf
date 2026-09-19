output "resource_group_name" {
  description = "Name of the resource group containing all resources in this module."
  value       = azurerm_resource_group.main.name
}

output "vnet_id" {
  description = "ID of the application virtual network."
  value       = azurerm_virtual_network.main.id
}

output "private_subnet_id" {
  description = "Private subnet ID delegated to the Container Apps environment (no direct internet route)."
  value       = azurerm_subnet.private.id
}

output "public_subnet_id" {
  description = "Public subnet ID (Application Gateway tier only)."
  value       = azurerm_subnet.public.id
}

output "evidence_storage_account_name" {
  description = "Name of the compliance evidence/audit-log Storage Account. Query target for audit evidence generation."
  value       = azurerm_storage_account.evidence.name
}

output "evidence_storage_account_id" {
  description = "Resource ID of the evidence storage account, for use in downstream RBAC role assignments or Policy definitions."
  value       = azurerm_storage_account.evidence.id
}

output "evidence_container_name" {
  description = "Name of the evidence blob container within the storage account."
  value       = azurerm_storage_container.evidence.name
}

output "evidence_kms_key_id" {
  description = "ID of the Key Vault key (CMK) used to encrypt the evidence store and container registry."
  value       = azurerm_key_vault_key.evidence.id
}

output "key_vault_id" {
  description = "ID of the Key Vault holding the evidence/registry encryption key."
  value       = azurerm_key_vault.main.id
}

output "ci_build_application_client_id" {
  description = "Client (application) ID GitHub Actions uses to request an Entra ID token for build/test/staging stages, via the federated identity credential."
  value       = azuread_application.ci_build.client_id
}

output "ci_deploy_production_application_client_id" {
  description = "Client (application) ID GitHub Actions uses for the production deploy job. Only usable once the `production` GitHub Environment approval gate has passed (federated credential subject scoped to environment:production)."
  value       = azuread_application.ci_deploy_production.client_id
}

output "azure_tenant_id" {
  description = "Entra ID tenant ID, required alongside the client IDs above for azure/login@v2's OIDC-based sign-in in ci-cd/pipeline.yml."
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "Subscription ID, required for azure/login@v2 and for az CLI commands scoped to this subscription."
  value       = data.azurerm_client_config.current.subscription_id
}

output "container_registry_login_server" {
  description = "Login server (FQDN) of the Azure Container Registry the pipeline pushes signed images to."
  value       = azurerm_container_registry.main.login_server
}

output "container_app_environment_name" {
  description = "Name of the Container Apps environment hosting the application."
  value       = azurerm_container_app_environment.main.name
}

output "container_app_name" {
  description = "Name of the Container App the pipeline updates on each deploy."
  value       = azurerm_container_app.app.name
}

output "container_app_environment_default_domain" {
  description = "Default domain of the Container Apps environment, used as the Application Gateway's backend pool target."
  value       = azurerm_container_app_environment.main.default_domain
}

output "application_gateway_public_ip" {
  description = "Public IP address of the Application Gateway — the application's public entry point."
  value       = azurerm_public_ip.appgw.ip_address
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID backing Container Apps logs, Activity Log, and Entra Audit Log exports."
  value       = azurerm_log_analytics_workspace.main.id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string for app-level distributed tracing (the X-Ray equivalent)."
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "hipaa_hitrust_policy_assignment_id" {
  description = "ID of the built-in HIPAA/HITRUST regulatory-compliance Policy initiative assignment providing the independent compliance witness."
  value       = azurerm_resource_group_policy_assignment.hipaa_hitrust.id
}
