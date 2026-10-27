# Frontend Containerization Reference (`frontend/Dockerfile`, `.dockerignore` & `nginx.conf`)

This document explains every architectural and security decision in [`frontend/Dockerfile`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/Dockerfile), [`frontend/.dockerignore`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/.dockerignore), and [`frontend/nginx.conf`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/nginx.conf).

---

## 1. Why Multi-Stage Builds Are Essential for React / Vite Frontends

Unlike a Node.js backend (which executes JavaScript on the server for every HTTP request), a React/Vite Single-Page Application (SPA) only needs Node.js **during the build step** to compile `.jsx` and `.css` source files into static browser files (`.html`, `.css`, `.js`).

By splitting [`frontend/Dockerfile`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/Dockerfile) into two stages:
1. **Stage 1 (`FROM node:22-alpine AS builder`):** Installs all build tools (`vite`, `@vitejs/plugin-react`, `node_modules`) and compiles the static bundle into `/app/dist`.
2. **Stage 2 (`FROM nginxinc/nginx-unprivileged:1.27-alpine`):** Copies **only** the compiled `/app/dist` folder into a lightweight Nginx web server. Everything from Stage 1 (`node`, `npm`, `node_modules`, source code) is completely discarded!

### Real Impact on Our Image (Backend vs. Frontend)
| Metric | `opsticket-backend:test` (Single-Stage Node) | `opsticket-frontend:test` (Multi-Stage Nginx) |
| :--- | :--- | :--- |
| **Uncompressed Size (`DISK USAGE`)** | `273 MB` | **`92.9 MB`** |
| **Compressed Size (`CONTENT SIZE`)** | `66.4 MB` | **`26.5 MB`** |
| **Language Packages in Final Image** | `157` npm packages | **`0` npm packages** |
| **Trivy Vulnerabilities (Total)** | `0` OS / `0` App (`15` unfixed npm CLI) | **`0` OS / `0` App (`0` total!)** |

---

## 2. Production `frontend/Dockerfile` Reference

```dockerfile
# =============================================================================
# Stage 1: Build React SPA Static Assets
# =============================================================================
FROM node:22-alpine AS builder

WORKDIR /app

# 1. Install Dependencies (Cached Layer)
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# 2. Copy Source & Compile Production Bundle (Uses relative /api path)
COPY . .
RUN npm run build

# =============================================================================
# Stage 2: Serve Static Assets with Unprivileged Nginx
# =============================================================================
FROM nginxinc/nginx-unprivileged:1.27-alpine

# 1. Apply Alpine OS Security Updates (requires root UID 0 briefly, then drop back)
USER 0:0
# hadolint ignore=DL3018
RUN apk upgrade --no-cache

# 2. Copy Built Assets & SPA Routing Config (UID/GID 101 = nginx)
COPY --chown=101:101 --from=builder /app/dist /usr/share/nginx/html
COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf

# 3. Runtime Execution & Healthcheck as Non-Root User
USER 101:101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/"]
CMD ["nginx", "-g", "daemon off;"]
```

---

## 3. Key Design Decisions Explained

### A. Why `npm ci` (Not `npm ci --omit=dev`) in Stage 1?
* In [`frontend/package.json`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/package.json), both `vite` and `@vitejs/plugin-react` live under `devDependencies`.
* If you ran `npm ci --omit=dev` in Stage 1, `npm run build` (`vite build`) would fail with `sh: vite: not found`.
* Installing `devDependencies` in Stage 1 is 100% safe because Stage 1 is thrown away and never ships to production.

### B. "Build Once, Deploy Anywhere": Why We Use Nginx `/api/` Proxy Instead of `ARG VITE_API_URL`
* **The Trap with `ARG VITE_API_URL` + `ENV VITE_API_URL`:**
  Because Vite compiles code into static `.js` files that run in the user's browser, passing `ARG VITE_API_URL=http://localhost:3000` at build time permanently bakes that URL into the compiled JavaScript bundle. That makes the Docker image **environment-dependent** (forcing you to rebuild the image from scratch for Staging vs. Production!).
* **The DevOps Standard (Relative `/api` Path + Nginx Reverse Proxy):**
  In [`frontend/src/api.js`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/src/api.js#L1), `const API_URL = import.meta.env.VITE_API_URL || '';` defaults to an empty string `''` when `VITE_API_URL` is omitted, causing all `fetch()` calls to hit the relative path **`/api/...`**.
  * We omit `ARG`/`ENV VITE_API_URL` from `frontend/Dockerfile` so the image is 100% **environment-agnostic** ("Build Once, Deploy Anywhere").
  * In [`frontend/nginx.conf`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/nginx.conf), we add a `location /api/` block (`proxy_pass http://backend:3000;`) so Nginx forwards `/api/*` requests internally to the backend container!
  * *(Note: If you ever work on a legacy project where `ARG VITE_API_URL` is required, always place `ARG`/`ENV` **below** `RUN npm ci` and right above `RUN npm run build` so changing the URL doesn't invalidate the `npm ci` layer cache.)*

### C. Why `/app/dist` Instead of `/app/build`?
Different frontend build tools output to different folder names by default:
* **Vite (`vite build`):** Outputs to **`/app/dist`** (used in this project).
* **Create React App (`react-scripts build`):** Outputs to `/app/build`.
* **Next.js (static export):** Outputs to `/app/out`.
Always verify the build tool in `package.json` (`"build": "vite build"`) before writing `COPY --from=builder`.

### D. Unprivileged Nginx (`nginxinc/nginx-unprivileged:1.27-alpine`), Port `8080`, and UID `101:101`
* Standard `nginx:alpine` runs master processes as `root` and binds to privileged port `80`.
* Official `nginxinc/nginx-unprivileged:1.27-alpine` is pre-configured to run as the non-root `nginx` user (**numeric UID/GID `101:101`**) and listen on unprivileged port **`8080`** (since Linux blocks non-root users from binding to ports below `1024`).
* Because the base image already switches to `USER 101`, running `RUN apk upgrade --no-cache` requires temporarily switching to root (`USER 0:0`) and then switching back to `USER 101:101`. Using numeric `0:0` instead of `root` satisfies Hadolint rule `DL3066`.

---

## 4. SPA Routing & `/api/` Reverse Proxy (`frontend/nginx.conf`)

```nginx
server {
    listen 8080;
    server_name localhost;

    # Serve React/Vite static SPA files
    location / {
        root /usr/share/nginx/html;
        index index.html index.htm;
        try_files $uri $uri/ /index.html;
    }

    # Reverse Proxy: Forward /api/* requests to the backend service
    location /api/ {
        proxy_pass http://backend:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
* **Why `try_files $uri $uri/ /index.html;` is mandatory for React Router:**
  When a user visits `http://localhost/tickets/42` or refreshes the page on `/login`, the browser asks Nginx for a physical file at `/usr/share/nginx/html/tickets/42`. Without `try_files ... /index.html`, Nginx returns `404 Not Found`. With `try_files`, Nginx falls back to serving `/index.html` whenever a static file doesn't exist, allowing React Router to handle the route in the browser.
* **Why `proxy_pass http://backend:3000;` Has NO Trailing Slash (`/`):**
  * If you write `proxy_pass http://backend:3000/;` (with a trailing `/`), Nginx **strips `/api/`** from the request and sends `/auth/login` to the backend (which fails with `404 Not Found`).
  * Writing `proxy_pass http://backend:3000;` (**no** trailing slash) preserves the full `/api/auth/login` path when forwarding to the Express backend!

---

## 5. Why `nginx.conf` Must NOT Be in `frontend/.dockerignore`

In [`frontend/.dockerignore`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/frontend/.dockerignore), we ignore `Dockerfile`, `.dockerignore`, `node_modules`, `dist`, `build`, `.env*`, and test files—but we **must not** ignore `nginx.conf` because Stage 2 runs:
```dockerfile
COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
```
If `nginx.conf` were listed in `.dockerignore`, Docker's build context would exclude it and Stage 2 would fail with `file not found`.
