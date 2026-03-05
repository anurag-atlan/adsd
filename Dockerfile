FROM node:99-alpine-does-not-exist
WORKDIR /app
COPY . .
CMD ["node", "a.ts"]
