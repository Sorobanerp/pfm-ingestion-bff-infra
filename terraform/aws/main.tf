terraform {
  required_version = ">= 1.8.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.75"
    }
  }
}

variable "environment" {
  type        = string
  default     = "prod"
  description = "Target deployment environment (local, staging, prod)"
}

variable "aws_region" {
  type        = string
  default     = "us-east-2"
  description = "Primary AWS Region (Ohio)"
}

variable "shared_state_bucket" {
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
  description = "S3 bucket storing pfm-shared-infra remote state"
}

variable "kms_master_key_arn" {
  type        = string
  default     = ""
  description = "Optional override for KMS Master Key ARN (defaults to pfm-shared-infra remote state output)"
}

variable "oidc_provider_arn" {
  type        = string
  default     = ""
  description = "Optional override for EKS OIDC Provider ARN (defaults to pfm-shared-infra remote state output)"
}

variable "oidc_issuer_url" {
  type        = string
  default     = ""
  description = "Optional override for EKS OIDC Issuer URL without https:// (defaults to pfm-shared-infra remote state output)"
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.shared_state_bucket
    key    = "pfm-shared-infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  kms_master_key_arn = coalesce(var.kms_master_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, ""))
  oidc_provider_arn  = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  oidc_issuer_url    = coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
}

# 1. Dedicated S3 Bucket for KMS-Encrypted Credit Card Statements (SSE-KMS)
resource "aws_s3_bucket" "statements_encrypted" {
  bucket = "pfm-statements-encrypted-${var.environment}"

  tags = {
    Service     = "pfm-ingestion-bff-go"
    Environment = var.environment
    ManagedBy   = "OpenTofu"
    Compliance  = "ADR-006-Envelope-Encryption"
  }
}

resource "aws_s3_bucket_public_access_block" "statements_encrypted" {
  bucket                  = aws_s3_bucket.statements_encrypted.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "statements_encrypted" {
  bucket = aws_s3_bucket.statements_encrypted.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "statements_encrypted" {
  bucket = aws_s3_bucket.statements_encrypted.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.kms_master_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# 2. Dedicated IAM Role (IRSA) & KMS Envelope Encryption Policy exclusively for pfm-ingestion-bff-go
data "aws_iam_policy_document" "irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_url}:sub"
      values   = ["system:serviceaccount:pfm-banking:pfm-ingestion-bff-go-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingestion_bff_role" {
  name               = "pfm-ingestion-bff-go-irsa-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role.json
}

data "aws_iam_policy_document" "ingestion_s3_kms_policy" {
  statement {
    sid    = "AllowEncryptedStatementsBucketPutGet"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.statements_encrypted.arn,
      "${aws_s3_bucket.statements_encrypted.arn}/*"
    ]
  }

  statement {
    sid    = "AllowKmsEnvelopeEncryptionForTenants"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]
    resources = [local.kms_master_key_arn]
  }
}

resource "aws_iam_role_policy" "ingestion_bff_policy" {
  name   = "pfm-ingestion-bff-s3-kms-policy"
  role   = aws_iam_role.ingestion_bff_role.id
  policy = data.aws_iam_policy_document.ingestion_s3_kms_policy.json
}

output "s3_bucket_name" {
  value = aws_s3_bucket.statements_encrypted.bucket
}

output "iam_role_arn" {
  value = aws_iam_role.ingestion_bff_role.arn
}
