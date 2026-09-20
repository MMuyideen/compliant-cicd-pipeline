FROM node:26-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

EXPOSE 8080
USER node
CMD ["node", "src/index.js"]
