# 🛠️ Troubleshooting & Break-and-Fix Log

This document records every issue, error, and misconception encountered during the project in **chronological order**—showing the symptom, root cause, and exact fix so future debugging is fast and structured.

---

## Issue #01 — Entrypoint Path Mismatch (`server.js` vs `src/server.js`)
* **Stage:** `backend/Dockerfile` (Stage 1 → Stage 2)
* **Symptom / Potential Error:**
  ```text
  Error: Cannot find module '/app/server.js'
  ```
* **Root Cause:**
  Generic Node.js Dockerfile templates assume `server.js` is in the root of `backend/`, so they use `CMD [ "node", "server.js" ]`. However, in this project (`backend/package.json`), `"main"` and `"start"` point to `src/server.js`.
* **Fix:**
  Always check `package.json` (`"main"` and `"scripts.start"`) when adapting a template to a project, and point `CMD` to `src/server.js`.

---

## Issue #02 — Missing Database Tables on Fresh PostgreSQL Container (`relation "users" does not exist`)
* **Stage:** `backend/Dockerfile` (`CMD` instruction)
* **Symptom / Potential Error:**
  Container starts and `/health` passes, but registering or logging in fails with `500 Internal Server Error` (`error: relation "users" does not exist`).
* **Root Cause:**
  * Unlike MongoDB (MERN stack), which is schemaless and creates collections automatically when data is first saved, **PostgreSQL is a strict SQL database**.
  * Provisioning PostgreSQL (via Docker or Terraform) only creates an **empty** database (`opsticket`) with **0 tables**.
  * The table structure (`users` and `tickets`) lives in `backend/migrations/` and must be applied at **runtime** (not `RUN` build time, when no DB is connected) via `npm run migrate` (`knex migrate:latest`).
* **Fix:**
  Chain the migration before starting the server using `exec` so `node` replaces the `sh` shell and remains the direct child of `tini` (PID 1):
  ```dockerfile
  CMD [ "sh", "-c", "npm run migrate && exec node src/server.js" ]
  ```

---

## Issue #03 — Docker CLI Commands (`docker ls`, `docker ps <image>`, and `U` "In Use" Images)
* **Stage:** Local Image Inspection (`backend`)
* **Symptoms:**
  1. `docker ls` → `docker: unknown command: docker ls`
  2. `docker ps opsticket-backend:test` → `docker: 'docker ps' accepts no arguments`
  3. `docker images` shows `U` (In Use) next to old lab images even though `docker ps` shows 0 running containers.
* **Root Cause & Explanation:**
  1. To list images, the command is `docker images` (or `docker image ls`).
  2. `docker ps` lists **running containers**, not images. To filter `docker images` by name, run `docker images opsticket-backend:test`.
  3. `docker ps` only shows **currently running** containers. Stopped containers (visible via `docker ps -a`) still hold a lock on their image, causing Docker to mark the image as `U` (In Use).
  4. In `docker images`:
     * **`CONTENT SIZE` (e.g., `50.9MB`):** Compressed size transferred over the internet when pushing/pulling to ECR or Docker Hub.
     * **`DISK USAGE` (e.g., `217MB`):** Uncompressed size extracted on your local disk.

---

## Issue #04 — Hadolint Warnings Still Showing After Updating (`DL3018` & `DL3066`)
* **Stage:** Linting `backend/Dockerfile` with Hadolint
* **Symptom:**
  After editing and deleting the Docker image, running `docker run --rm -i hadolint/hadolint < Dockerfile` still printed:
  ```text
  -:5 DL3018 warning: Pin versions in apk add.
  -:23 DL3066 info: Non-numeric user-id may not be resolvable by host system
  ```
* **Root Cause:**
  1. The edits had accidentally been made inside `docs/backend-dockerfile.md` instead of the actual `backend/Dockerfile` on disk!
  2. Also note: Hadolint only reads the text file (`< Dockerfile`)—it never looks at the built Docker image, so deleting the image (`docker rmi`) is not needed when re-testing Hadolint.
* **Fix:**
  Updated the actual `backend/Dockerfile` with:
  * `# hadolint ignore=DL3018` above `RUN apk upgrade --no-cache && apk add --no-cache tini`
  * Numeric UID/GID `1000:1000` in `COPY --chown=1000:1000 . .` and `USER 1000:1000`
  Re-running Hadolint produced **0 output (exit code 0 = 100% pass)**.

---

## Issue #05 — Massive 1,296-Line Trivy Output & Remediating 117 Vulnerabilities
* **Stage:** Scanning `opsticket-backend:test` with Trivy
* **Symptoms:**
  1. Initial Trivy scan output was 1,296 lines long and hard to read in the terminal.
  2. Scan reported **51 Alpine OS vulnerabilities** (including 4 `HIGH` in OpenSSL `libcrypto3`/`libssl3`) and **66 Node.js vulnerabilities** (including a `CRITICAL` IP-spoofing flaw in `proxy-addr`).
  3. Running `npm audit fix --package-lock-only` still printed 37 warnings in the terminal for `nodemon` and `jest`.
* **Root Cause:**
  1. By default, Trivy includes a `summary` table that prints a row for every single clean (`0`) package in `node_modules` (820 lines of `0`s).
  2. The cached `node:20-alpine` image had older Alpine OpenSSL packages (`3.5.6-r0` vs `3.5.8-r0`), and `backend/package-lock.json` had older sub-dependencies for `express` (`proxy-addr@2.0.7`, `qs@6.15.2`).
  3. The 37 remaining warnings in `npm audit` were in `devDependencies` (`jest`, `nodemon`), which are excluded from the production container by `npm ci --omit=dev`.
* **Fix:**
  1. **Readable Output:** Used `--table-mode detailed` and redirected to `> trivy-backend.txt` (cutting the file from 1,296 lines down to 140 lines).
  2. **OS Fix:** Upgraded to `FROM node:22-alpine` and added `RUN apk upgrade --no-cache && apk add --no-cache tini` → **Alpine OS vulnerabilities dropped from 51 to 0**.
  3. **App Fix:** Ran `npm audit fix --package-lock-only` → upgraded `express` (`4.22.3`), `proxy-addr` (`2.0.8`), `qs` (`6.16.1`), `body-parser` (`1.20.8`), `ip-address` (`10.7.4`), and `brace-expansion` (`1.1.21`) → **Active Express app vulnerabilities dropped to 0**.

---

## Issue #06 — Vite vs. Create-React-App Output Folder (`/app/build` vs `/app/dist`)
* **Stage:** `frontend/Dockerfile` (`COPY --from=builder`)
* **Symptom / Potential Error:**
  ```text
  ERROR: failed to solve: failed to compute cache key: "/app/build": not found
  ```
* **Root Cause:**
  Older Create React App (`react-scripts build`) projects output compiled static files to `/app/build`, whereas **Vite (`vite build`)** outputs compiled files to **`/app/dist`** by default.
* **Fix:**
  Check `"scripts.build"` in `frontend/package.json` (`"vite build"`) and copy from `/app/dist`:
  ```dockerfile
  COPY --chown=101:101 --from=builder /app/dist /usr/share/nginx/html
  ```

---

## Issue #07 — Placing `ARG`/`ENV` Above `npm ci` Breaks Docker Layer Caching
* **Stage:** `frontend/Dockerfile` (Stage 1 `builder`)
* **Symptom:**
  Every time `VITE_API_URL` is changed in `--build-arg VITE_API_URL=...`, Docker invalidates the `RUN npm ci` cache and downloads/installs all packages from scratch.
* **Root Cause:**
  Docker evaluates layer cache top-to-bottom. Placing `ARG VITE_API_URL` and `ENV VITE_API_URL=${VITE_API_URL}` at the top of the `builder` stage (above `COPY package*.json ./` and `RUN npm ci`) tells Docker that `npm ci` depends on that variable.
* **Fix:**
  Move `ARG VITE_API_URL` and `ENV VITE_API_URL=${VITE_API_URL}` **below** `RUN npm ci` and `COPY . .`, immediately above `RUN npm run build` (the only step that actually reads `VITE_API_URL`).

---

## Issue #08 — `USER root` Triggers Hadolint `DL3066` in `nginx-unprivileged` Stage 2
* **Stage:** Linting `frontend/Dockerfile` with Hadolint
* **Symptom:**
  Running `docker run --rm -i hadolint/hadolint < Dockerfile` reported:
  ```text
  -:25 DL3066 info: Non-numeric user-id may not be resolvable by host system
  ```
* **Root Cause:**
  Because `nginxinc/nginx-unprivileged:1.27-alpine` defaults to non-root user `101`, Stage 2 must briefly switch to `root` to run `apk upgrade --no-cache` before dropping back to `USER 101:101`. However, writing `USER root` uses a text name instead of a numeric UID, which triggers Hadolint `DL3066`.
* **Fix:**
  In Linux, the `root` user and group always have numeric ID `0:0`. Replacing `USER root` with `USER 0:0` on line 25 resolved `DL3066` and gave a 100% clean Hadolint pass.

---

## Issue #09 — `trivy-frontend.txt` Created as an Empty (0-Byte) File
* **Stage:** Scanning `opsticket-frontend:test` with Trivy (`--table-mode detailed`)
* **Symptom:**
  Running `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy image --table-mode detailed opsticket-frontend:test > trivy-frontend.txt` produced a completely empty (`0` byte) file.
* **Root Cause:**
  This was actually a **100% clean scan (`0` vulnerabilities)**!
  1. Because `frontend/Dockerfile` is a **multi-stage build**, Stage 1 (`node:22-alpine`) and all `node_modules` / `npm` packages were completely discarded (`Number of language-specific files: num=0`).
  2. In Stage 2 (`nginxinc/nginx-unprivileged:1.27-alpine`), `RUN apk upgrade --no-cache` patched all 68 Alpine OS packages to `0` vulnerabilities.
  3. When `--table-mode detailed` finds `0` vulnerabilities across both OS and language packages, it prints **nothing** to `stdout`, resulting in a 0-byte redirected file!
* **Fix / Verification:**
  Ran Trivy without `--table-mode detailed` (or with summary output) to confirm the `0` vulnerability table and saved the full verification summary in `frontend/trivy-frontend.txt`.

---

## Issue #10 — `dclint` Errors (`no-unbound-port-interfaces`, `no-build-and-image`) & Key Ordering Warnings
* **Stage:** Linting `docker-compose.yml` with `zavoloklom/dclint`
* **Symptoms:**
  1. `no-unbound-port-interfaces`: Flagged `backend` (`"${BACKEND_PORT:-3000}:${PORT:-3000}"`) and `frontend` (`"${FRONTEND_PORT:-80}:8080"`) as errors while passing `database` (`"127.0.0.1:${DB_PORT:-5432}:5432"`).
  2. `no-build-and-image`: Flagged services that defined both `build:` and `image:`.
  3. `require-project-name-field`, `require-quotes-in-ports`, `service-keys-order`, and `services-alphabetical-order` warnings.
* **Root Cause:**
  1. Exposing ports without an interface IP (`127.0.0.1:`) binds them to `0.0.0.0` on the host and bypasses `ufw` firewall rules.
  2. Defining both `build:` and `image:` in the same `docker-compose.yml` creates ambiguity between pulling from a registry vs. building locally.
  3. `dclint` enforces single quotes `'...'` around port mappings with variables and a canonical ordering of service keys.
* **Fix:**
  1. Added `name: opsticket` at line 1 (which automatically names built images `opsticket-backend` and `opsticket-frontend` without needing `image:` alongside `build:`).
  2. Prefixed `backend` and `frontend` ports with `127.0.0.1:` in single quotes.
  3. Ran `docker run --rm -v "$(pwd):/app" zavoloklom/dclint --fix /app/docker-compose.yml` → **0 errors, 0 warnings**.

---

## Issue #11 — `trivy config /workspace/docker-compose.yml` Reports `Supported files for scanner(s) not found`
* **Stage:** Running Trivy IaC Misconfiguration Scanner
* **Symptom:**
  Running `docker run --rm -v "$(pwd):/workspace" aquasec/trivy config /workspace/docker-compose.yml` output `Detected config files: num=0` and `WARN Supported files for scanner(s) not found`.
* **Root Cause:**
  Trivy's `config` (misconfiguration) scanner has built-in rule engines for `Dockerfile`, Terraform (`.tf`), Kubernetes, Helm, and CloudFormation—not `docker-compose.yml` (which is validated using `docker compose config` and `dclint`).
* **Fix:**
  Pointed `trivy config` at the repository directory (`/workspace`) instead of `docker-compose.yml`:
  ```bash
  docker run --rm -v "$(pwd):/workspace" aquasec/trivy config /workspace
  ```
  Trivy automatically discovered both `backend/Dockerfile` and `frontend/Dockerfile` (`Detected config files: num=2`).

---

## Issue #12 — Trivy `DS-0026` (`Add HEALTHCHECK instruction`) vs. Hadolint `DL3025` (`JSON notation for CMD`)
* **Stage:** Resolving the final `LOW` misconfiguration in `trivy config /workspace`
* **Symptoms:**
  1. `trivy config /workspace` reported `DS-0026 (LOW): Add HEALTHCHECK instruction in your Dockerfile` on both `backend/Dockerfile` and `frontend/Dockerfile`.
  2. When `HEALTHCHECK ... CMD wget ... || exit 1` was added in shell form, Hadolint flagged:
     `DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments`
* **Root Cause:**
  1. Even when `healthcheck:` is defined in `docker-compose.yml`, `trivy config` evaluates each `Dockerfile` in isolation to ensure standalone containers also have healthchecks.
  2. Hadolint's `DL3025` rule checks `CMD` inside `HEALTHCHECK` and prefers JSON array exec notation (`CMD ["wget", ...]`) over shell notation. Because `wget --spider` already returns exit code `0` on `200 OK` and non-zero on failure, shell `|| exit 1` is unnecessary!
* **Fix:**
  Added JSON array `HEALTHCHECK` to both `Dockerfile`s:
  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
      CMD ["wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/health"]
  ```
  Both Hadolint (`0` warnings) and `trivy config /workspace` (**`0` misconfigurations — 27/27 checks passed**) succeeded cleanly!

---

## Issue #13 — Browser Shows `Cross-Origin Request Blocked ... Status code: (null)` on Login
* **Stage:** End-to-End Browser Testing with Docker Compose
* **Symptom:**
  Attempting to log in on `http://localhost` failed in the browser console with:
  ```text
  NetworkError when attempting to fetch resource.
  Cross-Origin Request Blocked: The Same Origin Policy disallows reading the remote resource at http://localhost:3000/api/auth/login. (Reason: CORS request did not succeed). Status code: (null).
  ```
* **Root Cause (Two-Part Detective Trail):**
  1. **Why the browser said `Status code: (null)`:** When a browser sends a cross-origin request (`http://localhost` → `http://localhost:3000`) and the target server is **completely unreachable (`ECONNREFUSED`)**, Firefox still reports it as a failed CORS request, but with **`Status code: (null)`** (meaning no HTTP response was received at all).
  2. **Why `backend` was crashing (`Restarting (1)`):** Checking `docker logs` on the backend container revealed:
     ```text
     Using environment: production
     Already up to date
     /app/src/app.js:14
       throw new Error('FRONTEND_URL environment variable is required');
     ```
     In [`backend/src/app.js`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/backend/src/app.js#L12-L18), the server requires `process.env.FRONTEND_URL` to configure `app.use(cors({ origin: FRONTEND_URL }))` and throws a fatal error on startup if `FRONTEND_URL` is missing!
* **Fix:**
  Added `FRONTEND_URL: ${FRONTEND_URL:-http://localhost}` to `backend.environment` in [`docker-compose.yml`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/docker-compose.yml#L16) so the backend passes its startup check and permits CORS requests from `http://localhost`.

---

## Issue #14 — Build-Time `ARG VITE_API_URL` vs. Nginx `/api/` Reverse Proxy ("Build Once, Deploy Anywhere")
* **Stage:** Architectural Refactor (`frontend/Dockerfile.template`, `frontend/nginx.conf` & `docker-compose.template.yml`)
* **Problem:**
  1. Using `ARG VITE_API_URL` and `ENV VITE_API_URL` in `frontend/Dockerfile` bakes the backend URL directly into the compiled JavaScript bundle at build time—making the Docker image environment-dependent (cannot promote the same image from Staging to Production without rebuilding).
  2. Exposing `ports:` on `database` (`5432`) and `backend` (`3000`) increases host surface area when all traffic can enter through `frontend` (`80`).
* **Solution & Key Gotchas:**
  1. **Relative `/api` Path + Nginx Reverse Proxy:** Because [`frontend/src/api.js`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/src/api.js#L1) uses `const API_URL = import.meta.env.VITE_API_URL || '';`, omitting `VITE_API_URL` causes all frontend requests to use the relative path `/api/...`.
  2. **Nginx Trailing Slash Trap:** Added `location /api/ { proxy_pass http://backend:3000; }` to [`frontend/nginx.conf`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/nginx.conf) **without** a trailing slash after `3000` (writing `http://backend:3000/;` with a trailing slash would strip `/api/` and cause `404 Not Found` on the Express backend).
  3. **Single Entry Point:** Removed `ARG`/`ENV VITE_API_URL` from `frontend/Dockerfile.template` and removed host `ports:` from `database` and `backend` in `docker-compose.template.yml` so only `frontend` exposes port `80` (`127.0.0.1:${FRONTEND_PORT:-80}:8080`).
  4. **Secret Syntax (`:-` vs `:?`):** Documented that plain `${DB_PASSWORD}` silently defaults to an empty string `""` in Docker Compose; use `${DB_PASSWORD:-postgres}` for zero-config local/interview demos, and `${DB_PASSWORD:?error}` when you want Compose to fail if a production secret is missing.

