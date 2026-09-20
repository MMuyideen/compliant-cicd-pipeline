terraform {
  backend "azurerm" {
    resource_group_name  = "terraform-backend-rg"
    storage_account_name = "deenterraformstate"
    container_name       = "tfstate"
    key                  = "compliant-cicd-pipeline.tfstate"
  }
}