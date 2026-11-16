terraform {
  required_version = ">= 1.8.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "southamerica-east1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "kms_crypto_key_id" {
  type        = string
  description = "Cloud KMS CryptoKey ID from pfm-shared-infra"
}

resource "google_service_account" "ingestion_bff_sa" {
  account_id   = "pfm-ingestion-bff-go-${var.environment}"
  display_name = "PFM Ingestion BFF Go Service Account"
  project      = var.project_id
}

resource "google_storage_bucket" "statements_encrypted" {
  name                        = "pfm-statements-encrypted-${var.project_id}-${var.environment}"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true

  encryption {
    default_kms_key_name = var.kms_crypto_key_id
  }
}

resource "google_kms_crypto_key_iam_member" "kms_encrypter_decrypter" {
  crypto_key_id = var.kms_crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.ingestion_bff_sa.email}"
}

output "service_account_email" {
  value = google_service_account.ingestion_bff_sa.email
}
