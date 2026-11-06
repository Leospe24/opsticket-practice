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
  Replaced `dynamodb_table = "opsticket-tf-locks"` with `use_lockfile = true` inside the `backend "s3"` configuration block in `terraform/provider.tf` and re-initialized:
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
  Updated `aws_ecr_repository` in `terraform/ecr.tf` to use `force_delete = true`:
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
  AWS discontinued onboarding new AWS accounts onto AWS App Runner starting April 30, 2026.
* **Resolution / Architectural Refactor:**
  Removed `terraform/apprunner.tf` and refactored our compute architecture to a self-contained **Custom VPC (`vpc.tf`) + Security Group (`security.tf`) + IAM Instance Profile (`iam.tf`) + EC2 Container Host (`ec2.tf`)**.

---

## Issue #05 — HCL Syntax & Bash Line-Wrap Catches Across `iam.tf`, `vpc.tf`, `security.tf`, and `ec2.tf`
* **Stage:** Code inspection before `terraform validate` / `terraform apply`
* **Symptoms & Root Causes:**
  1. **`iam.tf` (`Actions = "sts:AssumeRole"`):** Typed plural `Actions` instead of singular **`Action`**, which causes AWS IAM to reject the JSON policy document with `MalformedPolicyDocument`.
  2. **`vpc.tf` (`route = {`) & `security.tf` (`ingress = {` / `egress = {`):** Used an `=` sign on sub-blocks. In HCL, `tags = {` uses `=` because `tags` is a key-value map, whereas `route {`, `ingress {`, and `egress {` are configuration blocks and do not use `=`.
  3. **`vpc.tf` (`Name = opsticket-public-rt`):** Omitted double quotes `"..."` around the string value, causing HCL to interpret hyphens `-` as subtraction operators.
  4. **`ec2.tf` (`values = ["al2023-ami-2023.*-86_64"]`):** Omitted the `x` in `-x86_64`, which would cause `data "aws_ami"` to return zero matching images.
  5. **`ec2.tf` (`user_data` line wrapping):** Wrapping `${aws_ecr_repository.frontend.repository_url}` onto a new line without a trailing backslash `\` causes Bash to execute `docker login` and `docker run` prematurely without the image URL argument.
* **Fix:**
  Corrected all 5 syntax items and ran `terraform fmt` and `terraform validate` inside `./terraform` to standardize 2-space HCL formatting.

---

## Issue #06 — Trivy CI Scan Fails with `AWS-0104 (CRITICAL): Security group rule allows unrestricted egress to any IP address`
* **Stage:** GitHub Actions CI (`terraform` job — `Trivy IAC Config Scan`) on `terraform/security.tf`
* **Symptom:**
  ```text
  AWS-0104 (CRITICAL): Security group rule allows unrestricted egress to any IP address.
  security.tf:19 via security.tf:14-20 (egress)
  19 [     cidr_blocks = ["0.0.0.0/0"]
  ```
* **Root Cause:**
  1. Trivy's `AWS-0104` (`AVD-AWS-0104`) rule flags any Security Group `egress` block with `cidr_blocks = ["0.0.0.0/0"]`.
  2. Because our lab uses a free **Internet Gateway** (rather than paid $21/month AWS PrivateLink VPC Endpoints inside `10.0.0.0/16`), outbound internet access (`0.0.0.0/0`) is required so the EC2 server can reach dynamically changing public IPs for `dnf install docker`, AWS ECR, and Docker Hub.
* **Fix:**
  Added a surgical inline Trivy ignore comment (`# trivy:ignore:AVD-AWS-0104`) directly above the `egress` block in [`terraform/security.tf`](../../terraform/security.tf) so only the `web` Security Group's outbound rule is exempted.

---

## Issue #07 — Database vs. Backend Container Credential Mismatch in `ec2.tf` (`POSTGRES_USER` vs `DB_USER`)
* **Stage:** Upgrading `terraform/ec2.tf` (`user_data`) to run the 3-tier stack (`database` + `backend` + `frontend`)
* **Symptom / Catch:**
  In `user_data`, the `database` container was configured with `-e POSTGRES_USER=opsticket` / `-e POSTGRES_PASSWORD=opsticket`, while the `backend` container was configured with `-e DB_USER=postgres` / `-e DB_PASSWORD=postgres`.
* **Root Cause:**
  When `postgres:16-alpine` initializes with `POSTGRES_USER=opsticket`, it creates the superuser as `opsticket` instead of `postgres`. If `backend` attempts to connect as `DB_USER=postgres`, PostgreSQL rejects the connection with `password authentication failed`.
* **Fix:**
  Aligned both containers in [`terraform/ec2.tf`](../../terraform/ec2.tf) to use `opsticket` for both `POSTGRES_USER`/`DB_USER` and `POSTGRES_PASSWORD`/`DB_PASSWORD`.

---

## Issue #08 — `docker push` Fails with `The repository with name 'opsticket-backend' does not exist in the registry`
* **Stage:** Pushing `opsticket-backend:v1` to AWS ECR after running `terraform destroy` and `terraform plan`
* **Symptom:**
  ```text
  error from registry: The repository with name 'opsticket-backend' does not exist in the registry with id '977308214565'
  ```
* **Root Cause:**
  1. Running `terraform destroy` earlier deleted the existing ECR repository, and `terraform plan` only previews changes without creating resources in AWS.
  2. Unlike Docker Hub (which auto-creates repositories on `docker push`), AWS ECR strictly requires the repository to be provisioned **before** `docker push` is executed.
* **Fix:**
  Executed the **3-Phase Sequence**:
  1. Created the 2 empty ECR repositories first:
     ```bash
     terraform apply -target=aws_ecr_repository.frontend -target=aws_ecr_repository.backend -auto-approve
     ```
  2. Pushed `opsticket-backend:v1` and `opsticket-frontend:v1` to ECR.
  3. Ran `terraform apply -auto-approve` to launch the custom VPC and EC2 server, which pulled all 3 containers and served the full application.

---

## Issue #09 — AWS Free Tier $100 Promotional Credit Immediately Expired on Account Creation Day
* **Stage:** AWS Billing & Cost Management Console (`Credits`)
* **Symptom:**
  The `$100.00` AWS Free Tier sign-up credit (`10068701050`) showed `Status: Expired` on `10/10/2026` (the exact day the account was opened) with `$0.00` used.
* **Root Cause:**
  Under AWS's credit-based Free Tier terms, enrolling a Free Plan account into **AWS Organizations** (which happens automatically when enabling IAM Identity Center / SSO multi-account setups) immediately upgrades the account from the **Free Plan** to the **Paid Plan** and permanently expires all Free Tier promotional credits.
* **Mitigation for Lab Practice:**
  1. Set a **$5 AWS Billing Alert** in CloudWatch/Billing.
  2. All VPC, Subnet, Internet Gateway, Route Table, Security Group, and IAM resources cost **$0.00**.
  3. EC2 `t3.micro` instances are billed per-second (~$0.01/hour = ~$0.0016 for a 6-minute test) and are immediately terminated after verification using `terraform destroy -auto-approve`.
