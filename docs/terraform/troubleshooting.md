# 🛠️ Troubleshooting & Break-and-Fix Log (Terraform & AWS)

This document records issues, warnings, and architectural discoveries encountered during **Day 3: Infrastructure as Code (Terraform & AWS)** in **chronological order**—showing the symptom, root cause, and exact fix so future debugging is fast and structured.

---

## Issue #01 — `403 AccessDenied` When Creating S3 Bucket & DynamoDB Table
* **Stage:** `terraform-bootstrap/` (`terraform apply`)
* **Symptoms:**
  ```text
  Error: creating S3 Bucket (opsticket-tf-state-patrick-lab): operation error S3: CreateBucket, https response error StatusCode: 403, api error AccessDenied: User: arn:aws:iam::308916794074:user/leo is not authorized to perform: s3:CreateBucket
  Error: creating AWS DynamoDB Table (opsticket-tf-locks): operation error DynamoDB: CreateTable, https response error StatusCode: 400, api error AccessDeniedException
  ```
* **Root Cause:**
  1. `terraform plan` on an empty state only verifies basic AWS credential syntax and calculates planned changes locally—it does not test real write permissions for creating resources.
  2. The terminal session defaulted to the `default` AWS profile (`user/leo` in Account 1), which had been restricted in favor of an STS AssumeRole / Identity Center (SSO) admin profile in Account 2 (`auditor-admin`).
* **Fix:**
  Switched the active AWS profile in the terminal session rather than hardcoding credentials or profiles inside `.tf` files (which would break CI/CD portability):
  ```bash
  export AWS_PROFILE="auditor-admin"
  aws sso login
  aws sts get-caller-identity
  terraform apply
  ```

---

## Issue #02 — Deprecated Parameter `dynamodb_table` Warning in Terraform 1.16+
* **Stage:** `terraform/` (`terraform init`)
* **Symptom:**
  ```text
  Warning: Deprecated Parameter
  The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
  ```
* **Root Cause:**
  Historically, Amazon S3 lacked native conditional write locking, requiring an external DynamoDB table with a primary key named `LockID`. Modern versions of Terraform (1.10+ / 1.16+) take advantage of native S3 Conditional Writes (`If-None-Match`), allowing S3 to manage state locks directly via `.tflock` files inside the bucket.
* **Fix:**
  Replaced `dynamodb_table = "opsticket-tf-locks"` with `use_lockfile = true` inside the `backend "s3"` configuration block in `terraform/providers.tf` and re-initialized:
  ```hcl
  backend "s3" {
    bucket       = "opsticket-tf-state-patrick-lab"
    key          = "opsticket/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
  ```
  ```bash
  terraform init -reconfigure
  ```

---

## Issue #03 — Unsupported Argument `force_destroy` on `aws_ecr_repository`
* **Stage:** `terraform/` (`terraform plan` on ECR configuration)
* **Symptom:**
  ```text
  Error: Unsupported argument
  An argument named "force_destroy" is not expected here.
  ```
* **Root Cause:**
  An API naming inconsistency exists within the Terraform AWS Provider:
  * On S3 buckets (`aws_s3_bucket`), the parameter to force-delete non-empty buckets is `force_destroy`.
  * On ECR repositories (`aws_ecr_repository`), the AWS API parameter is `forceDelete`, so the Terraform attribute is named **`force_delete`**.
* **Fix:**
  Updated `aws_ecr_repository` in `terraform/main.tf` to use `force_delete = true`:
  ```hcl
  resource "aws_ecr_repository" "frontend" {
    name         = "opsticket-frontend"
    force_delete = true
  }
  ```

---

## Issue #04 — `InvalidRequestException: Account can'tcreate new App Runner services` & Service Sunset
* **Stage:** `terraform/` (`terraform apply` on `aws_apprunner_service`)
* **Symptoms:**
  1. Terraform returned an AWS API error:
     ```text
     Error: creating App Runner Service (opsticket-frontend): operation error AppRunner: CreateService, https response error StatusCode: 400, InvalidRequestException: Account 977308214565 can'tcreate new App Runner services.
     ```
  2. AWS Console displayed an official service sunset banner:
     ```text
     Notice: Starting April 30, 2026, AWS App Runner is no longer accepting new customers. Your existing App Runner services will remain operational and accessible... For deploying and running containerized applications, we recommend Amazon ECS Express Mode.
     ```
* **Root Cause:**
  1. AWS officially placed AWS App Runner into maintenance mode, discontinuing onboarding for new accounts starting April 30, 2026, and deprecating the service in favor of **Amazon ECS Express Mode** and **Amazon ECS Fargate**.
  2. Newer AWS accounts have default App Runner service creation limits set to `0` by policy.
* **Resolution / Architectural Decision:**
  1. Preserved the completed ECR repository (`aws_ecr_repository.frontend`) and IAM Role (`aws_iam_role.apprunner_ecr_role`).
  2. Removed the `aws_apprunner_service` block from active deployment to prevent failed applies.
  3. Documented the transition from App Runner to Amazon ECS / ECS Express Mode for modern container compute workloads.
