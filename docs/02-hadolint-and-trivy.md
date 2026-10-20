# 02 — Hadolint & Trivy: Container Linting, Security Scanning & Remediation Guide

This document explains **why** we use **Hadolint** and **Trivy**, **how** they differ from `docker build`, the exact **commands and flags** used in the industry, and **how to triage and fix** what they find.

---

## 1. The Big Picture: The 3-Step Verification Pipeline

When you write a `Dockerfile`, running `docker build` only proves that the syntax doesn't crash—it does **not** prove the image is secure, small, or written to industry standards.

In both local testing and CI/CD pipelines (`ci.yml`), tools run in this exact order:

```text
[1. Hadolint] (0.5s)  -->  [2. docker build] (20s)  -->  [3. Trivy] (15s)
Checks the recipe          Bakes the image               Scans the finished image
(Dockerfile text)          into layers                   for OS & package CVEs
```

* **Why Hadolint runs FIRST:** It only reads the `Dockerfile` text file and takes half a second. If there is a bad practice in your `Dockerfile`, it catches it immediately before you waste time running `docker build`.
* **Why Trivy runs LAST:** Trivy needs the **built image** so it can open the filesystem layers and inspect every installed OS library and language package.

---

## 2. Hadolint (Dockerfile Linter)

### What Is Its Purpose?
Hadolint (**Ha**skell **Do**ckerfile **Lint**er) acts like a senior engineer reviewing your `Dockerfile` code against official Docker best practices. It also has **ShellCheck** built in to validate bash commands inside `RUN` instructions.

Examples of mistakes `docker build` ignores that **Hadolint catches**:
* `DL3007`: Using `FROM node:latest` instead of a pinned version.
* `DL3019`: Using `apk add` without `--no-cache`.
* `DL3025`: Using shell form `CMD node server.js` instead of exec array `CMD ["node", "server.js"]`.
* `DL3066`: Using a text username (`USER node`) instead of a numeric UID/GID (`USER 1000:1000`).

### Command Used
Run Hadolint as a disposable container (no host installation needed):

```bash
docker run --rm -i hadolint/hadolint < Dockerfile
```
* `--rm`: Automatically deletes the container as soon as the check finishes.
* `-i`: Keeps `stdin` open so `< Dockerfile` can stream your file into the container.
* **Expected output when 100% clean:** Nothing (returns straight to the terminal prompt with exit code `0`).

### Key Rules We Encountered & How to Handle Them

#### 1. `DL3018 warning: Pin versions in apk add`
* **Why it triggers:** `RUN apk add --no-cache tini` doesn't lock a specific version (like `tini=0.19.0-r3`).
* **Industry Standard Fix:** Add `# hadolint ignore=DL3018` right above the `RUN` line:
  ```dockerfile
  # hadolint ignore=DL3018
  RUN apk upgrade --no-cache && apk add --no-cache tini
  ```
* **Why we ignore `DL3018` on Alpine:** Alpine Linux deletes old package versions from its servers whenever a new security patch is released. If you hardcode `tini=0.19.0-r2`, your Docker build will suddenly break months later when Alpine updates it to `-r3`.

#### 2. `DL3066 info: Non-numeric user-id may not be resolvable by host system`
* **Why it triggers:** Using `USER node` (a text name) instead of `USER 1000:1000` (numbers).
* **Why `1000:1000` is the universal standard across all languages (Node, Python, Go):**
  * In Linux, UID `0` is always `root`, and regular non-root users start at **`1000`**.
  * In strict Kubernetes clusters (`runAsNonRoot: true`), Kubernetes checks the image before starting the container. If it sees `USER node` (text), it cannot verify that `"node"` isn't root without booting the container first. Using `USER 1000:1000` proves immediately that the user is non-root.
  * **Important difference across base images:**
    * **`node:22-alpine`:** Already comes with UID/GID `1000:1000` (`node`) pre-created out of the box.
    * **`python` / `golang` images:** Do **not** have user `1000` pre-created, so you create it first before switching:
      ```dockerfile
      RUN addgroup -g 1000 -S app && adduser -u 1000 -S app -G app
      USER 1000:1000
      ```

---

## 3. Trivy (Container Vulnerability & Secret Scanner)

### What Is Its Purpose?
Even if your `Dockerfile` is 10/10, the packages inside your base image (`alpine`) or your `package-lock.json` might have newly discovered security flaws (**CVEs** — Common Vulnerabilities and Exposures) or accidentally baked-in secrets.

Trivy unpacks the built Docker image and scans:
1. **OS Packages:** Alpine (`apk`), Ubuntu/Debian (`apt`), RedHat (`rpm`).
2. **Application Dependencies:** Automatically detects **any** language (`package-lock.json` for Node, `requirements.txt`/`poetry.lock` for Python, `go.mod`/binaries for Go, etc.) using the exact same command!
3. **Leaked Secrets:** API keys, `.env` passwords, private keys.

### Commands & Filtering Flags

#### 1. Scan and Strip Out All `0` (Clean) Packages
By default, Trivy prints a massive 800+ line `summary` table listing every single package with `0` vulnerabilities. Passing `--table-mode detailed` removes all the `0`s while keeping all real findings (`LOW`, `MEDIUM`, `HIGH`, `CRITICAL`):

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image \
  --table-mode detailed \
  opsticket-backend:test > trivy-backend.txt
```
* **Why `-v /var/run/docker.sock:/var/run/docker.sock` is required:** Because `opsticket-backend:test` only exists locally on your laptop (not on Docker Hub), mounting the Docker socket lets the Trivy container read images from your host's Docker daemon.

#### 2. Useful Optional Flags for CI/CD or Quick Triage
* `--severity HIGH,CRITICAL`: Only displays `HIGH` and `CRITICAL` vulnerabilities.
* `--ignore-unfixed`: Hides vulnerabilities where the package author has not released a fix yet (`Fixed Version` is blank).
* `.trivyignore` file: Just like `.gitignore`, you can list specific CVE IDs inside a `.trivyignore` file after the dev/security team reviews and approves ignoring them.

---

## 4. How to Read & Remediate a Trivy Report (The 3-Bucket Method)

Every Trivy report is divided into **OS Packages** and **Language Packages**, and every finding falls into one of **3 buckets**:

| Bucket | Where It Comes From | How to Fix It (Remediation) |
| :--- | :--- | :--- |
| **Bucket 1: OS Packages** (`alpine`) | Outdated core Linux libraries in the base image (e.g., `libcrypto3`, `libssl3`, `zlib`). | **DevOps Fix (in `Dockerfile`):** Upgrade base image (e.g., `node:22-alpine`) and add `apk upgrade --no-cache` to the `RUN apk` instruction. |
| **Bucket 2: Active App Dependencies** (`/app/node_modules`) | Libraries actually imported by your running server (e.g., `express`, `proxy-addr`, `qs`, `body-parser`). | **Dev Fix (in app folder):** Run `npm audit fix --package-lock-only` to update `package-lock.json` to patched versions without needing to install `node_modules` on the host. |
| **Bucket 3: Non-Runtime / Unfixed Tools** (`/usr/local/lib/node_modules/npm`) | Packages inside the global `npm` CLI tool baked into the base Node image (`tar`, `pacote`, `sigstore`) or `devDependencies` (`jest`, `nodemon`). | **Safe to Ignore / `.trivyignore`:** Your running `node src/server.js` process never imports these, and `npm ci --omit=dev` already excludes `jest` and `nodemon` from the container. |

> **Golden Rule on `npm audit fix --force`:** Never run `--force` blindly. It often downgrades packages across major versions (e.g., downgrading `nodemon` to an ancient 1.x release) and introduces breaking changes. Always check `npm audit --omit=dev` to see what actually affects production.
