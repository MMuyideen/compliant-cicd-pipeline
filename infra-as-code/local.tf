locals {
  key_vault_name = "${substr(var.project_name, 0, 6)}-${substr(var.environment, 0, 4)}-kv-${substr(replace(data.azurerm_client_config.current.subscription_id, "-", ""), 0, 8)}"
}