FROM node:18-alpine AS builder
WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY server.js logger.js ./
COPY public ./public

FROM node:18-alpine
WORKDIR /app

COPY --from=builder /app /app

EXPOSE 8080

CMD ["node", "server.js"]
