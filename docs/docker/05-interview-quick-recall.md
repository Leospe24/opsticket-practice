# 05 — Live Interview Quick-Recall Templates (The 3-Minute Versions)

Use these **minimal, high-recall versions** for your **daily speed practice (Mon–Fri)** and **live 45-minute technical interviews**.
* **In a Live Interview:** Write the minimal version below from memory in 3 minutes so the app runs immediately, then **verbally mention** the production upgrades from [`01`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/docs/01-backend-dockerfile.md)–[`04`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/docs/04-docker-compose.md).
* **In a 48-Hour Take-Home Assessment (OnyxNexus Style):** Use the full hardened versions in [`01`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/docs/01-backend-dockerfile.md)–[`04`](file:///home/leo/leo/daily-practice-lab/opsticket-practice/ops-ticket-devops-lab/docs/04-docker-compose.md).

---

## Step 0: The 2-Minute Pre-Flight Check (When Given an Assessment Repo)

Before writing a single line of Docker code in a technical test, spend 2 minutes checking 4 things in their repo:
1. **`backend/package.json`:**
   * What is the start file? (`"main": "src/server.js"` vs `"server.js"`)
   * Is there a DB migration script? (`"migrate": "knex migrate:latest"`)
2. **`backend/` source code (`server.js`, `app.js`, `db.js` / `knexfile.js`):**
   * What port does it listen on? (`PORT || 3000`)
   * What `process.env` variables throw an error if missing? (`DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_PORT`, `JWT_SECRET`, `FRONTEND_URL`)
   * What is the health check endpoint? (`/health` or `/api/health`)
3. **`frontend/package.json` & `frontend/src/`:**
   * Does `"build"` run `vite build` (outputs to **`/app/dist`**) or `react-scripts build` (outputs to **`/app/build`**)?
   * What is the API URL variable name? (`VITE_API_URL` or `REACT_APP_API_URL`)

---

## 1. Minimal `backend/Dockerfile` (9 Lines)

```dockerfile
FROM node:22-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY --chown=node:node . .
USER node

EXPOSE 3000
CMD ["sh", "-c", "npm run migrate && node src/server.js"]
```

### 🎙️ What to Say Out Loud to the Interviewer While Typing:
> *"I'm keeping this Dockerfile clean and minimal so we can get the stack up fast: `node:22-alpine`, caching `package*.json` with `npm ci --omit=dev` before copying source code, dropping privileges to the non-root `node` user, and running migrations before starting the server. In a full production setup, I also add `apk upgrade --no-cache`, `tini` as PID 1 for signal handling, numeric UID `1000:1000`, a built-in `HEALTHCHECK`, and scan it with Hadolint and Trivy."*

---

## 2. Minimal `frontend/Dockerfile` (12 Lines) + `frontend/nginx.conf` (15 Lines)

### `frontend/Dockerfile`
```dockerfile
# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Serve
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```

### `frontend/nginx.conf`
```nginx
server {
    listen 8080;
    server_name localhost;

    location / {
        root /usr/share/nginx/html;
        index index.html index.htm;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://backend:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### 🎙️ What to Say Out Loud to the Interviewer While Typing:
> *"For the React frontend, I use a 2-stage build so `node_modules` and build tools are completely discarded after compiling `/app/dist`, keeping the final image around 26MB with zero npm vulnerabilities. Instead of baking `ARG VITE_API_URL` into the bundle (which breaks 'Build Once, Deploy Anywhere'), the frontend calls relative `/api` paths and Nginx proxies `/api/` to `http://backend:3000`."*

---

## 3. Minimal `.dockerignore` (Same 6 Lines for Both `backend/` & `frontend/`)

```gitignore
node_modules
dist
build
.env*
.git
Dockerfile*
```

---

## 4. Minimal `docker-compose.yml` (36 Lines — Single Entry Point)

```yaml
services:
  database:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USER:-postgres}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME:-opsticket}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-postgres} -d ${DB_NAME:-opsticket}"]
      interval: 10s
      timeout: 5s
      retries: 5

  backend:
    build: ./backend
    restart: unless-stopped
    environment:
      PORT: 3000
      DB_HOST: database
      DB_PORT: 5432
      DB_USER: ${DB_USER:-postgres}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_NAME: ${DB_NAME:-opsticket}
      JWT_SECRET: ${JWT_SECRET}
      FRONTEND_URL: ${FRONTEND_URL:-http://localhost}
    depends_on:
      database:
        condition: service_healthy

  frontend:
    build: ./frontend
    restart: unless-stopped
    ports:
      - "127.0.0.1:80:8080"
    depends_on:
      - backend

volumes:
  postgres_data:
```

### 🎙️ What to Say Out Loud to the Interviewer While Typing:
> *"In `docker-compose.yml`, only the `frontend` Nginx container exposes port `80` bound to `127.0.0.1` as our Single Entry Point (API Gateway); `backend` and `database` stay completely isolated inside the Docker network. For this demo I used `:-` fallback defaults so the stack boots with zero `.env` setup; in production Compose files, I switch secrets to `:?` (`${JWT_SECRET:?required}`) so Compose refuses to start if secrets aren't provided."*

---

## 5. Minimal Operational Handover Template (For Assessment `README.md`)

When an assessment (like OnyxNexus) says *"document how another engineer would operate it"*, include these 4 short sections in your `README.md`:

```markdown
## Operations & Handover Runbook

### 1. Start the Stack
docker compose up -d --build

### 2. Verify Health & Logs
docker compose ps
curl -f http://localhost:3000/health
docker compose logs -f backend

### 3. Common Troubleshooting (Evidence-Based)
- **Backend `Restarting (1)`:** Run `docker compose logs backend` to check for missing required env vars (`FRONTEND_URL`, `DB_*`) or failed SQL migrations.
- **Database `unhealthy`:** Ensure `-d` in `pg_isready` matches `POSTGRES_DB`.

### 4. Stop / Reset Environment
docker compose down        # Stop containers (preserves DB data in postgres_data volume)
docker compose down -v     # Full reset (wipes DB volume)
```
