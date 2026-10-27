# Base Image
FROM node:22-alpine

# ENV
ENV NODE_ENV=production

# Workspace
WORKDIR /app

# Copy dependency
COPY package*.json /app

# Install Dependencies
RUN npm ci --omit=dev

# Copy backend files
COPY --chown=1000:1000 . .

# Expose
EXPOSE 3000

USER 1000

#Execute
CMD ["sh", "-c", "npm run migrate && node src/server.js"]
