# Docker Break & Fix Guide: Hadolint, Caching, and Process Management

This document records the hands-on troubleshooting experiments, best practices, and security rules explored during Docker containerization practice.

---

## 1. Quick Recall: Hadolint vs. Trivy

| Tool | Role / One-Liner | What it scans | When to run it |
| :--- | :--- | :--- | :--- |
| **Hadolint** | **The Code Inspector**<br>Checks *how you wrote* the Dockerfile syntax & style. | The text file (`Dockerfile`) | **Before building** (No Docker build needed) |
| **Trivy** | **The Security Scanner**<br>Checks *what is packaged inside* your container image. | Installed OS packages, npm libraries, secrets | **After building** (Image must be built first) |

---

## 2. Hands-on Experiments & Key Rules

### Experiment 1: Non-Numeric User ID (`DL3066`)
* **Issue:** Using `USER node` triggers Hadolint info/warning `DL3066`.
* **Why it matters:** Container orchestrators (like Kubernetes with `runAsNonRoot: true`) check numeric UIDs before starting the container. If a named user like `node` is used, Kubernetes must parse `/etc/passwd` inside the image filesystem, which can fail or violate strict admission policies.
* **Fix:**
  ```dockerfile
  USER 1000:1000
  ```

---

### Experiment 2: The `ADD` vs `COPY` Trap (`DL3020`) & `latest` Tag (`DL3007`)
* **`DL3007` (`FROM node:latest`):**
  * **Consequence:** Silent time-bomb. A major upstream release (e.g., Node 23) breaks builds or native dependencies (`bcrypt`) weeks later without warning.
  * **Fix:** Always pin at least the major version (e.g. `node:22-alpine`).
* **`DL3020` (`ADD package*.json /app`):**
  * **Consequence:** `ADD` has unpredictable magic: it unpacks compressed archives (`.tar.gz`) and fetches URLs, creating security risks (tar-slip path traversal).
  * **Fix:** Use explicit, predictable `COPY`.

---

### Experiment 3: Alpine Package Management (`DL3018`, `DL3019`)
* **`DL3019` (`RUN apk add curl` without `--no-cache`):**
  * **Consequence:** Alpine package cache `/var/cache/apk/*` is saved permanently into the image layer, adding 5–10 MB of bloat.
  * **Fix:** Use `apk add --no-cache <pkg>`.
* **`DL3018` (Pin versions in `apk add`):**
  * **The Alpine dilemma:** Alpine removes old minor package versions from its mirrors when security fixes arrive. Hardcoding versions can break future builds with 404 errors.
  * **DevOps Practice:** Use `--no-cache` and tell Hadolint to ignore `DL3018` for that specific command:
    ```dockerfile
    # hadolint ignore=DL3018
    RUN apk upgrade --no-cache && \
        apk add --no-cache tini
    ```

---

### Experiment 4: Build Layer Caching & Manifest Separation
* **Anti-pattern:** `COPY . .` followed immediately by `RUN npm ci`.
* **Consequence:** Any single line or comment edit in application code invalidates the Docker cache for `COPY . .`, forcing a 1–3 minute `npm ci` download every single build.
* **Best Practice:** Split manifest files from source code:
  ```dockerfile
  COPY package*.json ./
  RUN npm ci --omit=dev
  COPY --chown=1000:1000 . .
  ```
* **Advanced (BuildKit Cache Mount):**
  ```dockerfile
  RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev
  ```

---

### Experiment 5: Process ID 1 (PID 1), `exec`, and Graceful Shutdowns
* **Anti-pattern:** `CMD ["sh", "-c", "npm run migrate && node src/server.js"]`
* **Consequence:** `sh` runs as PID 1 and spawns `node` as a child. `sh` ignores `SIGTERM` signals from `docker stop` or Kubernetes. The container hangs for 10 seconds before being forcefully killed (`SIGKILL`), dropping active user requests and database connections.
* **Fix (Process Replacement):**
  ```dockerfile
  CMD ["sh", "-c", "npm run migrate && exec node src/server.js"]
  ```
  *(The `exec` keyword replaces the shell process with the Node.js process so Node receives signals directly).*
* **Best Practice (Init system with `tini`):**
  ```dockerfile
  ENTRYPOINT ["/sbin/tini", "--"]
  CMD ["sh", "-c", "npm run migrate && exec node src/server.js"]
  ```
  `tini` handles signal forwarding and reaps zombie/orphan processes.

---

## 3. Controlling Trivy Terminal Output

To prevent Trivy from flooding the terminal with hundreds of lines, use these targeted flags:

| Flag | Purpose |
| :--- | :--- |
| `--severity HIGH,CRITICAL` | Only displays actionable, high-risk CVEs (hides LOW, MEDIUM, UNKNOWN). |
| `--ignore-unfixed` | Hides vulnerabilities that do not have an official patch available yet. |
| `--quiet` (`-q`) | Suppresses download progress bars and initialization logs. |
| `--format table` | Clean, readable ASCII summary table. |

### Clean Local Trivy Command:
```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed --quiet opsticket-backend:latest
```
