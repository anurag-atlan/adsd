FROM node:99-alpine
WORKDIR /app
COPY . .
CMD ["node", "a.ts"]
