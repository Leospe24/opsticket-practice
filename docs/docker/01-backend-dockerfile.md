# 01 — Backend Dockerfile & `.dockerignore`: Line-by-Line Reference Guide

This document explains **what** every instruction in [`backend/Dockerfile`](../backend/Dockerfile) and [`backend/.dockerignore`](../backend/.dockerignore) does, **why** it is written this way for production, and **what would break** if it were removed.

---

## 1. The Complete `backend/Dockerfile`

```dockerfile
# =============================================================================
# Production Dockerfile — OpsTicket Backend API
# =============================================================================
FROM node:22-alpine

# 1. OS Security Updates & PID 1 Init System
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && \
    apk add --no-cache tini

# 2. Environment & Working Directory
ENV NODE_ENV=production
WORKDIR /app

# 3. Dependencies (Cached Layer)
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# 4. Application Source & Non-Root Privileges (UID/GID 1000 = node)
COPY --chown=1000:1000 . .
USER 1000:1000

# 5. Runtime Execution & Healthcheck
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/health"]
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["sh", "-c", "npm run migrate && exec node src/server.js"]
```

---

## 2. Line-by-Line Breakdown (`backend/Dockerfile`)

### `FROM node:22-alpine`

- **What it does:** Starts from the official Node.js v22 LTS image built on **Alpine Linux** (a tiny ~5 MB Linux distribution).
- **Why we use it:** The full default `node:22` image (Debian-based) is over **1 GB** and contains hundreds of OS packages (compilers, curl, git, etc.) that increase security vulnerabilities. `node:22-alpine` is ~130 MB and has a minimal attack surface.
- **What breaks if removed/changed:** Using `FROM node:latest` makes builds unpredictable when a new major Node version drops and bloats the image with unnecessary OS tools.

---

### `RUN apk upgrade --no-cache && apk add --no-cache tini`

- **What it does:** Uses Alpine's package manager (`apk`) to first upgrade all core OS libraries (`libcrypto3`, `libssl3`, `zlib`) to their latest security patches (`apk upgrade --no-cache`), and then installs `tini` (a tiny init system for containers). `--no-cache` tells Alpine not to leave downloaded package index files inside the image layer.
- **Why we use it:** Inside a Linux container, the first process started gets **PID 1** (Process ID 1), which has special OS responsibilities: forwarding stop signals (`SIGTERM`) and cleaning up "zombie" child processes. Node.js was **not** designed to run as PID 1.
- **What breaks if removed:** Without `apk upgrade`, Trivy flags 50+ OS vulnerabilities in OpenSSL. Without `tini`, when Docker or AWS ECS tries to stop the container (`docker stop`), Node might ignore `SIGTERM`, causing Docker to hang for 10 seconds before forcefully killing (`SIGKILL`) the app instead of running our graceful database shutdown in `src/server.js`.

---

### `ENV NODE_ENV=production`

- **What it does:** Sets the `NODE_ENV` environment variable to `production` inside the container.
- **Why we use it:** Frameworks like Express and database tools like Knex (`knexfile.js`) check `process.env.NODE_ENV`. In production mode, Express disables verbose stack traces (security) and caches view templates, while `knexfile.js` activates strict env var checks and SSL support.
- **What breaks if removed:** The app defaults to `development` mode, leaking internal error details and skipping production database checks in `knexfile.js`.

---

### `WORKDIR /app`

- **What it does:** Creates `/app` inside the container and sets it as the current working directory for all following commands (`COPY`, `RUN`, `CMD`).
- **Why we use it:** Keeps application files isolated in `/app` instead of dumping them into the Linux root directory (`/`).

---

### `COPY package*.json ./`

- **What it does:** Copies **only** `package.json` and `package-lock.json` into `/app` _before_ copying the rest of the source code.
- **Why we use it (Layer Caching):** Docker caches each instruction as a layer. If you change a line of code in `src/server.js`, Docker checks if `package.json` or `package-lock.json` changed. Since they didn't, Docker **skips reinstalling npm packages** and reuses the cached `RUN npm ci` layer—making rebuilds take 1 second instead of 30+ seconds.
- **What breaks if you do `COPY . .` before `npm ci`:** Every single code change in `src/` invalidates the cache and forces Docker to download and reinstall all `node_modules` from scratch.

---

### `RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev`

- **What it does:**
  1. `npm ci` ("Clean Install") installs exact dependency versions locked in `package-lock.json` (fails if `package.json` and `package-lock.json` are out of sync).
  2. `--omit=dev` skips `devDependencies` (`jest`, `nodemon`, `supertest`), which are only needed for testing/local dev.
  3. `--mount=type=cache,target=/root/.npm` tells Docker BuildKit to mount a temporary cache folder for npm downloads during the build **without saving `/root/.npm` into the final image**.
- **Why is `node_modules` installed as `root` here?** Because `USER node` hasn't been called yet, `/app/node_modules` is owned by `root:root`. The `node` user can **read and execute** those packages, but **cannot modify** them at runtime—protecting against malicious code injection if the app is ever compromised.

---

### `COPY --chown=node:node . .`

- **What it does:** Copies the remaining project files (filtered by `.dockerignore`) into `/app` and sets their ownership to the built-in non-root `node` user and `node` group.
- **Why we use it:** By default, `COPY` always copies files as `root:root`, even if `USER node` was set earlier. `--chown=node:node` changes ownership in the same layer without needing an extra `RUN chown -R` layer (which would double the size of copied files in Docker layers).

---

### `USER node`

- **What it does:** Switches the active user from `root` (UID 0) to the unprivileged `node` user (UID 1000) that comes pre-created in official Node images.
- **Why we use it (Least Privilege):** If an attacker finds a vulnerability in the Node app while running as `root`, they have root privileges inside the container. Running as `USER node` restricts what the process can touch.

---

### `EXPOSE 3000`

- **What it does:** Documents that the container listens on port `3000`.
- **Note:** `EXPOSE` does **not** actually publish the port to the host machine by itself—it serves as metadata for developers and tools (`docker-compose.yml` or `-p 3000:3000` actually opens the port).

---

### `ENTRYPOINT [ "/sbin/tini", "--" ]`

- **What it does:** Sets `/sbin/tini` as the container's PID 1 wrapper. Everything inside `CMD` is passed as arguments after `--` to `tini`.

---

### `CMD [ "sh", "-c", "npm run migrate && exec node src/server.js" ]`

- **What it does:**
  1. Runs `npm run migrate` (`knex migrate:latest`) to create or update the PostgreSQL table structure (`users` and `tickets` tables from `backend/migrations/`).
  2. Uses `&&` so that if database migration fails, the server refuses to start (fail-fast).
  3. Runs `exec node src/server.js`.
- **Why do we need `npm run migrate` here (SQL vs. MongoDB)?**
  - Unlike MongoDB (MERN), which creates collections automatically on the fly, **PostgreSQL is a strict SQL database**. Even on a brand-new database created by Docker or Terraform, the database starts with **0 tables**. `migrations/` creates the empty table structure (`CREATE TABLE users`, `CREATE TABLE tickets`), while `seeds/` is for dummy/starter data.
  - Migrations cannot run during `RUN` (build time) because no database is connected during `docker build`—they must run when the container boots (`CMD`).
- **Why `exec node src/server.js` instead of just `node src/server.js`?**
  - Because we used `sh -c` to chain two commands, `sh` is initially the child of `tini`. Using `exec` tells the `sh` shell to **replace itself in memory** with `node src/server.js`. That way, `node` becomes the direct child of `tini` and receives `SIGTERM`/`SIGINT` shutdown signals directly!

---

## 3. Why `backend/.dockerignore` Is Required

When `COPY --chown=node:node . .` runs, Docker sends everything in `backend/` to the build context unless excluded in [`backend/.dockerignore`](../backend/.dockerignore):

| Ignored Entry                 | Why It Must Be Ignored                                                                                                                |
| :---------------------------- | :------------------------------------------------------------------------------------------------------------------------------------ |
| `node_modules`                | Prevents copying host OS binaries (e.g., Ubuntu C++ builds of `bcrypt`) over the Alpine container's clean `npm ci --omit=dev` folder. |
| `.env`, `.env.*`              | Prevents baking local secrets/passwords into the Docker image layers.                                                                 |
| `tests`, `coverage`           | Unit tests and Jest coverage reports are only for development/CI, not production runtime.                                             |
| `Dockerfile`, `.dockerignore` | Prevents editing a comment in `Dockerfile` from invalidating the `COPY . .` layer cache.                                              |
| `.git`, `logs`, `*.md`        | Keeps the build context small and fast.                                                                                               |

---

## 4. Bookmarkable Industry-Standard Reference Links

When searching Google or asking AI with a generic prompt, you usually get basic "tutorial" Dockerfiles rather than hardened production configs. Here are the authoritative industry sources where these production patterns come from:

1. **[Official Node.js Docker Best Practices (`nodejs/docker-node`)](https://github.com/nodejs/docker-node/blob/main/docs/BestPractices.md)** — Written by the maintainers of the official `node` Docker image (covers `USER node`, `tini`, `CMD ["node", ...]`, `NODE_ENV`).
2. **[Docker Official Node.js Containerization Guide](https://docs.docker.com/guides/nodejs/containerize/)** — Official Docker docs showing `--mount=type=cache,target=/root/.npm` and `npm ci --omit=dev`.
3. **[Goldbergyoni's Node.js Best Practices — Docker Section](https://github.com/goldbergyoni/nodebestpractices#8-docker-best-practices)** — The most starred Node.js production guide on GitHub; explains multi-stage builds, `.dockerignore`, `tini`, and non-root users in detail.
4. **[OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)** — The security checklist used by DevSecOps teams (non-root user, minimal base images, no secrets in images).
5. **[Hadolint Rules Wiki](https://github.com/hadolint/hadolint/wiki)** — Lists every Dockerfile linting rule (`DL3000`–`DL3060`) with "bad vs. good" examples.
