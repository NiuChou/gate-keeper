FROM node:18-alpine
WORKDIR /app
RUN mkdir -p /app/tmp
RUN mkdir -p /tmp/cache
COPY . .
CMD ["node", "server.js"]
