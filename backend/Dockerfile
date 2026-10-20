# Base Image
FROM node:22-alpine

# Env
ENV NODE_ENV=production

# Work Directory
WORKDIR /app

# Copy package
COPY package*.json ./

# Install package
RUN npm ci --omit=dev

# Copy source file
COPY --chown=node:node . .

# Root Handover
USER node

# Expose
EXPOSE 3000

# Execute
CMD ["sh", "-c", "npm run migrate && node src/server.js"]