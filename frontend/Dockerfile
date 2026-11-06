# STAGE 1
# Base Image
FROM node:22-alpine AS builder

# Workspace
WORKDIR /app

# Copy dependency
COPY package*.json ./

# Install
RUN npm ci

# Copy source files
COPY . .

RUN npm run build

# STAGE 2
FROM nginxinc/nginx-unprivileged:1.27-alpine

USER 0:0
RUN apk upgrade --no-cache

COPY --from=builder /app/dist /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/default.conf

USER 101:101

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]