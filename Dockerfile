FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends fonts-dejavu-core fonts-liberation fontconfig && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY . .
RUN chown -R node:node /app

USER node
EXPOSE 3000
CMD ["node", "server.js"]
