terraform {
  required_version = ">= 1.8.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.75"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
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

variable "compute_engine" {
  description = "Compute engine for workloads: ecs_fargate_spot (ADR-008 Pilot) or eks"
  type        = string
  default     = "ecs_fargate_spot"
}

variable "shared_state_bucket" {
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
  description = "S3 bucket storing pfm-shared-infra remote state"
}

variable "image_repository" {
  description = "Container image repository"
  type        = string
  default     = "public.ecr.aws/docker/library/busybox"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "1.36"
}

variable "eks_cluster_name" {
  type        = string
  default     = ""
  description = "Optional override for EKS cluster name"
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
  eks_cluster_name   = coalesce(var.eks_cluster_name, try(data.terraform_remote_state.shared.outputs.eks_cluster_name, "pfm-eks-prod"))
  kms_master_key_arn = coalesce(var.kms_master_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, "arn:aws:kms:us-east-2:366476833548:alias/pfm-master-key"))
  oidc_provider_arn  = try(coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, null)), "")
  oidc_issuer_url    = try(coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, null)), "")

  # ECS Pilot Locals
  ecs_cluster_arn             = try(data.terraform_remote_state.shared.outputs.ecs_cluster_arn, "arn:aws:ecs:us-east-2:366476833548:cluster/pfm-pilot-prod")
  ecs_cluster_name            = try(data.terraform_remote_state.shared.outputs.ecs_cluster_name, "pfm-pilot-prod")
  ecs_tasks_security_group_id = try(data.terraform_remote_state.shared.outputs.ecs_tasks_security_group_id, "")
  cloud_map_namespace_arn     = try(data.terraform_remote_state.shared.outputs.cloud_map_namespace_arn, "")
  public_subnet_ids           = try(data.terraform_remote_state.shared.outputs.public_subnet_ids, [])
  private_subnet_ids          = try(data.terraform_remote_state.shared.outputs.private_subnet_ids, [])
  task_subnet_ids             = length(local.public_subnet_ids) > 0 ? local.public_subnet_ids : local.private_subnet_ids
  upstash_kafka_secret_arn    = try(data.terraform_remote_state.shared.outputs.upstash_kafka_secret_arn, "")
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
      kms_master_key_id = local.kms_master_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# =============================================================================
# Amazon ECS Fargate Spot & Service Connect Pilot (ADR-008)
# =============================================================================

resource "aws_iam_role" "ecs_execution_role" {
  count       = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name        = "pfm-ingestion-bff-ecs-exec-${var.environment}"
  description = "ECS Task Execution Role for pfm-ingestion-bff-go"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  count      = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  role       = aws_iam_role.ecs_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  count       = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name        = "pfm-ingestion-bff-ecs-task-${var.environment}"
  description = "Least Privilege Task Role for pfm-ingestion-bff-go (S3, KMS, Upstash)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_least_privilege" {
  count = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name  = "pfm-ingestion-bff-ecs-task-policy"
  role  = aws_iam_role.ecs_task_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEncryptedStatementsBucketPutGet"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.statements_encrypted.arn,
          "${aws_s3_bucket.statements_encrypted.arn}/*"
        ]
      },
      {
        Sid    = "AllowKmsEnvelopeEncryptionForTenants"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [local.kms_master_key_arn]
      },
      {
        Sid    = "UpstashKafkaSecretsAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  count             = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name              = "/ecs/pfm-ingestion-bff-go-${var.environment}"
  retention_in_days = 7

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_ecs_task_definition" "service" {
  count                    = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  family                   = "pfm-ingestion-bff-go-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role[0].arn
  task_role_arn            = aws_iam_role.ecs_task_role[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "pfm-ingestion-bff-go"
      image     = "${var.image_repository}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          name          = "http"
          containerPort = 18080
          hostPort      = 18080
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "bff"
        }
      }
      environment = [
        { name = "APP_ENV", value = "prod" },
        { name = "PORT", value = "18080" },
        { name = "STATEMENTS_BUCKET", value = aws_s3_bucket.statements_encrypted.bucket }
      ]
    }
  ])

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_ecs_service" "service" {
  count           = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name            = "pfm-ingestion-bff-go"
  cluster         = local.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.service[0].arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 0
  }

  network_configuration {
    subnets          = local.task_subnet_ids
    security_groups  = local.ecs_tasks_security_group_id != "" ? [local.ecs_tasks_security_group_id] : []
    assign_public_ip = true
  }

  dynamic "service_connect_configuration" {
    for_each = local.cloud_map_namespace_arn != "" ? [1] : []
    content {
      enabled   = true
      namespace = local.cloud_map_namespace_arn
      service {
        port_name      = "http"
        discovery_name = "pfm-ingestion-bff-go"
        client_alias {
          port     = 18080
          dns_name = "pfm-ingestion-bff-go.pfm.internal"
        }
      }
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_appautoscaling_target" "ecs_target" {
  count              = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${local.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu_policy" {
  count              = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name               = "pfm-ingestion-bff-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# =============================================================================
# EKS / Kubernetes Support (Optional / Legacy when compute_engine = "eks")
# =============================================================================

data "aws_eks_cluster" "eks" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = var.compute_engine == "eks" ? data.aws_eks_cluster.eks[0].endpoint : "https://127.0.0.1"
  cluster_ca_certificate = var.compute_engine == "eks" ? base64decode(data.aws_eks_cluster.eks[0].certificate_authority[0].data) : ""
  token                  = var.compute_engine == "eks" ? data.aws_eks_cluster_auth.eks[0].token : ""
}

provider "helm" {
  kubernetes {
    host                   = var.compute_engine == "eks" ? data.aws_eks_cluster.eks[0].endpoint : "https://127.0.0.1"
    cluster_ca_certificate = var.compute_engine == "eks" ? base64decode(data.aws_eks_cluster.eks[0].certificate_authority[0].data) : ""
    token                  = var.compute_engine == "eks" ? data.aws_eks_cluster_auth.eks[0].token : ""
  }
}

data "aws_iam_policy_document" "irsa_assume_role" {
  count = var.compute_engine == "eks" ? 1 : 0
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
      values   = ["system:serviceaccount:pfm-platform:pfm-ingestion-bff-go-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingestion_bff_role" {
  count              = var.compute_engine == "eks" ? 1 : 0
  name               = "pfm-ingestion-bff-go-irsa-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role[0].json
}

resource "aws_iam_role_policy" "ingestion_bff_policy" {
  count  = var.compute_engine == "eks" ? 1 : 0
  name   = "pfm-ingestion-bff-s3-kms-policy"
  role   = aws_iam_role.ingestion_bff_role[0].id
  policy = data.aws_iam_policy_document.ingestion_s3_kms_policy.json
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

resource "kubernetes_service_account_v1" "ingestion_bff_sa" {
  count = var.compute_engine == "eks" ? 1 : 0
  metadata {
    name      = "pfm-ingestion-bff-go-sa"
    namespace = "pfm-platform"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ingestion_bff_role[0].arn
    }
  }
}

resource "helm_release" "pfm_ingestion_bff" {
  count            = var.compute_engine == "eks" ? 1 : 0
  name             = "pfm-ingestion-bff-go"
  chart            = "${path.module}/../../helm"
  namespace        = "pfm-platform"
  create_namespace = false
  wait             = false
  values           = [file("${path.module}/../../helm/values-prod.yaml")]

  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.ingestion_bff_sa[0].metadata[0].name
  }

  depends_on = [kubernetes_service_account_v1.ingestion_bff_sa]
}

output "s3_bucket_name" {
  value = aws_s3_bucket.statements_encrypted.bucket
}

output "iam_role_arn" {
  value = try(aws_iam_role.ingestion_bff_role[0].arn, "")
}

output "ecs_service_name" {
  description = "ECS Service Name"
  value       = try(aws_ecs_service.service[0].name, "")
}

output "ecs_task_definition_arn" {
  description = "ECS Task Definition ARN"
  value       = try(aws_ecs_task_definition.service[0].arn, "")
}
