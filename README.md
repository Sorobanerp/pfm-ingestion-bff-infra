# `pfm-ingestion-bff-infra`

> **Repositório 1:1 IaC (ADR-002 & ADR-007) — OpenTofu/Terraform Multicloud (AWS, Azure, GCP), Helm Charts & Pipeline DevSecOps para `pfm-ingestion-bff-go`**

## Estrutura do Repositório

```text
pfm-ingestion-bff-infra/
├── terraform/
│   ├── aws/main.tf             # IAM Role IRSA, S3 Bucket SSE-KMS e Política KMS exclusiva
│   ├── azure/main.tf           # Managed Identity, Blob Container e Key Vault Crypto User
│   └── gcp/main.tf             # Service Account, GCS Bucket CMEK e Cloud KMS IAM
├── helm/
│   ├── Chart.yaml              # Metadados do Chart Kubernetes
│   ├── values-local.yaml       # Limites de RAM, Probes /health, HPA e endpoints LocalStack/Kafka
│   └── values-prod.yaml        # Produção HA com IRSA, HPA (3..15) e OpenTelemetry OTLP
└── .github/workflows/ci-cd.yml # Testes Go (-race), Gitleaks, Semgrep, Trivy e Build Distroless
```

---

## Topologia de Portas: Local Host vs. Kubernetes Cloud

- **Host Local (`values-local.yaml`):** HTTP `18100` (`SERVER_PORT`), Envoy `18080`, LocalStack `14566`, Kafka `19092`, Ledger `18200`/`18210`, Forecast `18110`.
- **Produção K8s (`values-prod.yaml`):** HTTP `8080` (Service & Container), Envoy `8080`, Kafka `9092`, Ledger `8080`/`9090`, Forecast `9090`.
