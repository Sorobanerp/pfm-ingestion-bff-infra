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
  default     = "sa-east-1"
  description = "Primary AWS Region (São Paulo)"
}

variable "kms_master_key_arn" {
  type        = string
  description = "ARN of alias/pfm-tenant-master-key exported by pfm-shared-infra"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS OIDC Provider ARN for IRSA Least-Privilege authentication"
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

resource "aws_s3_bucket_server_side_encryption_configuration" "statements_encrypted" {
  bucket = aws_s3_bucket.statements_encrypted.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_master_key_arn
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
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "system:serviceaccount:pfm-banking:pfm-ingestion-bff-go-sa"
      values   = ["system:serviceaccount:pfm-banking:pfm-ingestion-bff-go-sa"]
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
    resources = [var.kms_master_key_arn]
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
