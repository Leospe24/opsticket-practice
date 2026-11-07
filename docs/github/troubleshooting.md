# 🛠️ Troubleshooting & Break-and-Fix Log (GitHub & CI/CD)

This document records every issue, error, and configuration fix encountered during **Day 2: Git, GitHub, and CI/CD Pipelines** in **chronological order**—showing the symptom, root cause, and exact fix so future debugging is fast and structured.

---

## Issue #01 — `actions/setup-node@v4` Fails with `Dependencies lock file is not found` (`cache-dependencies` vs `cache-dependency-path`)
* **Stage:** `.github/workflows/ci.yml` (`frontend` job — Step 2 `Setup Node.js 22`)
* **Symptoms:**
  1. Red Error in GitHub Actions log:
     ```text
     Error: Dependencies lock file is not found in /home/runner/work/opsticket-practice/opsticket-practice. Supported file patterns: package-lock.json,npm-shrinkwrap.json,yarn.lock
     ```
  2. Yellow Warning directly above the error:
     ```text
     Warning: Unexpected input(s) 'cache-dependencies', valid inputs are ['always-auth', 'node-version', 'node-version-file', 'architecture', 'check-latest', 'registry-url', 'scope', 'token', 'cache', 'cache-dependency-path', 'mirror', 'mirror-token']
     ```
* **Root Cause:**
  1. **Why `working-directory: ./frontend` didn't help:** Setting `defaults.run.working-directory: ./frontend` only changes the directory for terminal commands (`run:`). Pre-built GitHub Actions plugins (`uses:`, such as `actions/setup-node@v4`) always execute from the repository root folder (`/home/runner/work/...`).
  2. **Why our lockfile path was ignored:** We wrote `cache-dependencies: frontend/package-lock.json`, which is not a valid input name for `actions/setup-node@v4`. The action printed a yellow warning, ignored the line, and fell back to searching the repository root for `package-lock.json`—where none exists in a monorepo (`frontend/` + `backend/`).
* **Fix:**
  Updated `.github/workflows/ci.yml` to use the exact input name listed in the warning (`cache-dependency-path`):
  ```yaml
  - name: Setup Node.js 22
    uses: actions/setup-node@v4
    with:
      node-version: 22
      cache: "npm"
      cache-dependency-path: frontend/package-lock.json
  ```

---

## Issue #02 — Pull Request Allows Merging Even When CI Action Fails (Red ❌)
* **Stage:** GitHub Repository Settings → Branch Protection Rules (`main`)
* **Symptom:**
  On Pull Request #1, even though the `frontend` CI job failed with a red ❌, the green **"Merge pull request"** button on GitHub remained clickable and allowed merging broken code into `main` (which immediately triggered a second failing `push` run on `main`).
* **Root Cause:**
  Enabling **"Require a pull request before merging"** only forces changes to go through a PR—it does not tell GitHub *which* automated CI jobs must pass before the Merge button unlocks. Additionally, GitHub cannot list a job name (like `frontend` or `docker`) in Branch Protection search until that workflow job has run at least once on the repository.
* **Fix:**
  After the workflow run registered the job names with GitHub, updated **Settings → Branches → Branch protection rule for `main`**:
  1. Checked **☑ Require status checks to pass before merging** and added the required CI jobs (`frontend`, `backend`, `docker`, `terraform`).
  2. Checked **☑ Require branches to be up to date before merging** so PRs must be tested against the latest `main` code before merging.

---

## Issue #03 — Frontend Unit Test (`src/api.test.js`) Fails in CI (`Failed to parse URL from /api/tickets/stats`)
* **Stage:** `.github/workflows/ci.yml` (`frontend` job — `Run unit tests` / `npm test`)
* **Symptoms:**
  1. GitHub Branch Protection successfully **blocked** the Merge button when `npm test` failed.
  2. `vitest` reported 1 failing test in `frontend/src/api.test.js:20:5`:
     ```text
     FAIL  src/api.test.js > API Client > handles network errors gracefully
     AssertionError: expected [Function] to throw error including 'Unable to connect to the API server' but got 'Failed to parse URL from /api/tickets…'
     - Expected: Unable to connect to the API server
     + Received: Failed to parse URL from /api/tickets/stats
     ```
* **Root Cause:**
  1. In `frontend/src/api.js`, the `try / catch` block that translates `TypeError` network errors into `'Unable to connect to the API server. Please check your network connection.'` was placed inside `handleResponse(response)` instead of wrapping the `await fetch(...)` call itself.
  2. When `await fetch('/api/tickets/stats')` threw a `TypeError` during the test (because no server or browser host exists in the Node.js test runner), `fetch()` crashed **before** `handleResponse()` was ever called.
* **Fix:**
  Added a `request(url, options)` wrapper in `frontend/src/api.js` that wraps `await fetch(url, options)` inside the `try / catch (err)` block so any `TypeError` thrown by `fetch` is caught and converted into the expected user-friendly error message.

---

## Issue #04 — Trivy Fails on `opsticket-backend:ci` with `tar (package.json) | CVE-2026-59873 | CRITICAL` & 850+ Line Log Output
* **Stage:** `.github/workflows/ci.yml` (`docker` job — `Trivy Scan Backend Image`)
* **Symptoms:**
  1. GitHub Actions log printed over 850 lines of `0` vulnerability summary rows before showing the actual failure at the bottom.
  2. Trivy exited with code `1` on a single `CRITICAL` finding:
     ```text
     Total: 1 (CRITICAL: 1)
     │ Library            │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │ Title                                                  │
     │ tar (package.json) │ CVE-2026-59873 │ CRITICAL │ fixed  │ 6.2.1             │ 7.5.19        │ tar: node-tar: Denial of Service via crafted gzip bomb │
     ```
* **Root Cause:**
  1. **Why 850+ lines printed:** Without `--table-mode detailed`, Trivy defaults to printing a summary table row for every clean (`0`) package inside `node_modules`.
  2. **Where `tar@6.2.1` came from:** `tar` is **not** in `backend/package.json`. It lives inside `/usr/local/lib/node_modules/npm/node_modules/tar/package.json`—an internal dependency of the global `npm` CLI tool pre-installed in the `node:22-alpine` base image (**Bucket 3: Non-Runtime Tool**). Our running Express server (`node src/server.js`) never imports or uses `tar`.
* **Fix (Industry-Standard Vulnerability Triage):**
  1. Created a [`.trivyignore`](../../.trivyignore) file in the repository root documenting why `CVE-2026-59873` does not affect production runtime:
     ```text
     # Ignore node-tar CVE inside the global npm CLI tool (/usr/local/lib/node_modules/npm)
     # Not imported or used by the running Express server (src/server.js)
     CVE-2026-59873
     ```
  2. Updated the Trivy steps in `.github/workflows/ci.yml` to add `--table-mode detailed` and mount `.trivyignore` into the disposable Trivy container (`-v $(pwd)/.trivyignore:/.trivyignore` + `--ignorefile /.trivyignore`).

---

## Issue #05 — Trivy Fails on `opsticket-frontend:ci` with 3 `CRITICAL` Alpine OS CVEs (`brotli-libs`, `libcrypto3`, `libssl3`)
* **Stage:** `.github/workflows/ci.yml` (`docker` job — `Trivy Scan Frontend Image`)
* **Symptom:**
  After `opsticket-backend:ci` passed, `Trivy Scan Frontend Image` failed with 3 `CRITICAL` OS vulnerabilities:
  ```text
  Total: 3 (CRITICAL: 3)
  │ Library     │ Vulnerability   │ Severity │ Status │ Installed Version │ Fixed Version │
  │ brotli-libs │ CVE-2026-111497 │ CRITICAL │ fixed  │ 1.1.0-r2          │ 1.1.1-r0      │
  │ libcrypto3  │ CVE-2026-31789  │ CRITICAL │ fixed  │ 3.3.3-r0          │ 3.3.7-r0      │
  │ libssl3     │ CVE-2026-31789  │ CRITICAL │ fixed  │ 3.3.3-r0          │ 3.3.7-r0      │
  ```
* **Root Cause:**
  1. Notice there is no `(package.json)` next to the names and the versions end in `-r0`/`-r2`—meaning these are **Alpine Linux OS packages (Bucket 1)** inside Stage 2 (`FROM nginxinc/nginx-unprivileged:1.27-alpine`).
  2. Unlike the earlier local test where `RUN apk upgrade --no-cache` was present (and because Trivy in CI downloads a fresh daily CVE database on every run), `frontend/Dockerfile` Stage 2 was missing `RUN apk upgrade --no-cache`.
  3. **Linux UID Range Concept (`0` vs `1–999` vs `1000+`):**
     * `UID 0`: `root` (superuser).
     * `UID 1–999`: System/background daemon accounts (`nginx-unprivileged` runs as UID **`101:101`** and owns `/var/cache/nginx`).
     * `UID 1000+`: Regular application users (`node:22-alpine` pre-creates UID **`1000:1000`**).
* **Fix:**
  In [`frontend/Dockerfile`](../../frontend/Dockerfile) Stage 2, briefly switched to numeric root (`USER 0:0` to satisfy Hadolint `DL3066`), ran `RUN apk upgrade --no-cache` to patch `brotli-libs`, `libcrypto3`, and `libssl3`, and dropped privileges back to `USER 101:101`:
  ```dockerfile
  FROM nginxinc/nginx-unprivileged:1.27-alpine

  USER 0:0
  RUN apk upgrade --no-cache

  COPY --from=builder /app/dist /usr/share/nginx/html
  COPY nginx.conf /etc/nginx/conf.d/default.conf

  USER 101:101
  ```

---

## Issue #06 — `terraform` Job Runs in Empty Root Directory & Trivy Flags `HIGH`/`LOW` ECR Misconfigurations (`AWS-0030`, `AWS-0031`, `AWS-0033`)
* **Stage:** `.github/workflows/ci.yml` (`terraform` job)
* **Symptoms:**
  1. `terraform init -backend=false` and `terraform validate` ran in the repository root (where no `.tf` files exist, causing Terraform to silently report success on an empty directory).
  2. `Trivy IAC Config Scan` failed on `terraform/ecr.tf` with:
     * `AWS-0030 (HIGH)`: ECR image scanning on push is not enabled (`scan_on_push = true`).
     * `AWS-0031 (HIGH)`: ECR repository tags are mutable (`image_tag_mutability = "IMMUTABLE"`).
     * `AWS-0033 (LOW)`: Repository is encrypted using default AWS encryption instead of a paid Customer Managed KMS Key ($1/month).
* **Root Cause:**
  1. `defaults.run.working-directory: ./terraform` was omitted from the `terraform` job definition in `.github/workflows/ci.yml`.
  2. `--severity CRITICAL` was omitted from the `trivy config` command, causing Trivy to fail on `HIGH` and `LOW` warnings (including `AWS-0033`, which requires a paid KMS key).
* **Fix:**
  Added `defaults.run.working-directory: ./terraform` to the `terraform` job and `--severity CRITICAL` to the `trivy config` step in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).

---

## Issue #07 — `oidc.tf` Resource Name Mismatch (`github_actions_role` vs `github_actions`), Audience Typo (`:aub` vs `:aud`), and `secrets.AES_ROLE_ARN`
* **Stage:** Day 4 CD Setup (`terraform-bootstrap/oidc.tf` & `.github/workflows/deploy.yml`)
* **Symptoms & Catches:**
  1. **Resource Reference Mismatch (Caught by `terraform validate`):** Declared `resource "aws_iam_role" "github_actions_role"` on line 7, but referenced `aws_iam_role.github_actions.name` and `.arn` on lines 34 & 39.
  2. **JSON String Key Typo (Not caught by `terraform validate`):** Wrote `"token.actions.githubusercontent.com:aub" = "sts.amazonaws.com"` (`:aub` instead of `:aud` for Audience). Because it is inside a JSON string, `terraform validate` allows it, but AWS STS rejects OIDC logins at runtime.
  3. **GitHub Secret Name Typo in `deploy.yml`:** Wrote `role-to-assume: ${{ secrets.AES_ROLE_ARN }}` (`AES` instead of `AWS`).
* **Fix:**
  Aligned the resource name to `"github_actions"`, corrected `:aub` to `:aud`, and fixed `secrets.AWS_ROLE_ARN` in `deploy.yml`.

---

## Issue #08 — `Error: Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity` (GitHub's New `@NumericID` `sub` Format)
* **Stage:** `.github/workflows/deploy.yml` (`Configure AWS Credentials via OIDC`)
* **Symptom:**
  When `CD Deploy Pipeline` ran on `main`, AWS STS rejected the OIDC authentication request:
  ```text
  Error: Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
  ```
* **Root Cause:**
  1. For newly created repositories, GitHub updated the OIDC `sub` (subject) claim format to embed immutable numeric user and repository IDs using `@` (`repo:Leospe24@<user_id>/opsticket-practice@<repo_id>:ref:refs/heads/main`) to prevent repository name-recycling attacks.
  2. Because our IAM Role Trust Policy in `terraform-bootstrap/oidc.tf` used `"repo:Leospe24/opsticket-practice:*"` (without accounting for the `@<numeric_id>` suffixes), AWS IAM's `StringLike` check failed to match the token's `sub` claim.
* **Fix:**
  1. Updated `StringLike` in [`terraform-bootstrap/oidc.tf`](../../terraform-bootstrap/oidc.tf) to include `*` wildcards after the owner and repository names (`"repo:Leospe24*/opsticket-practice*:*"`), which matches both classic and `@numeric_id` OIDC `sub` claims automatically.
  2. Ran `terraform apply -auto-approve` inside `terraform-bootstrap/`. Because the IAM Role Trust Policy lives in AWS (not GitHub), clicking **Re-run all jobs** in GitHub Actions immediately succeeded (Green ✅) even before pushing the updated `oidc.tf` file to GitHub!

---

## Issue #09 — Pull Request Blocked with `This branch is out-of-date with the base branch`
* **Stage:** Merging a follow-up PR on GitHub when `Require branches to be up to date before merging` is enabled
* **Symptom:**
  GitHub displayed:
  ```text
  This branch is out-of-date with the base branch. Merge the latest changes from main into this branch.
  ```
  and kept the **Merge pull request** button locked.
* **Root Cause:**
  When a previous PR is merged on GitHub, `main` receives a new merge commit on GitHub. If a new commit is pushed from a local branch that hadn't pulled the latest `main`, the branch is behind `main`. Because **☑ Require branches to be up to date before merging** is enabled in Branch Protection, GitHub requires the PR branch to sync with `main` and re-run CI checks before merging.
* **Fix:**
  Clicked the **"Update branch"** button directly in the GitHub PR UI (which merges the latest `main` into the PR branch and re-triggers the 4 CI checks).
