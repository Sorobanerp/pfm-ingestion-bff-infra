terraform {
  required_version = ">= 1.8.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "location" {
  type    = string
  default = "brazilsouth"
}

variable "resource_group_name" {
  type = string
}

variable "key_vault_id" {
  type        = string
  description = "Azure Key Vault ID from pfm-shared-infra for Envelope Encryption"
}

resource "azurerm_user_assigned_identity" "ingestion_bff_identity" {
  name                = "id-pfm-ingestion-bff-go-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_storage_account" "statements_storage" {
  name                     = "stpfmstatements${var.environment}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "statements_encrypted" {
  name                  = "pfm-statements-encrypted"
  storage_account_id    = azurerm_storage_account.statements_storage.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "key_vault_crypto_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.ingestion_bff_identity.principal_id
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.ingestion_bff_identity.client_id
}
