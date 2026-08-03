FROM node:20-bookworm-slim AS build

WORKDIR /app/Apps/MobileWeb
COPY Apps/MobileWeb/package.json Apps/MobileWeb/package-lock.json ./
COPY Apps/MobileWeb/protocol/package.json protocol/package.json
COPY Apps/MobileWeb/relay/package.json relay/package.json
COPY Apps/MobileWeb/web/package.json web/package.json
RUN npm ci

COPY Apps/MobileWeb/protocol protocol
COPY Apps/MobileWeb/relay relay
COPY Apps/MobileWeb/web web
RUN npm run build && npm prune --omit=dev

FROM node:20-bookworm-slim AS runtime

ENV NODE_ENV=production
ENV HOST=0.0.0.0
WORKDIR /app/Apps/MobileWeb
COPY --from=build /app/Apps/MobileWeb/package.json ./
COPY --from=build /app/Apps/MobileWeb/node_modules node_modules
COPY --from=build /app/Apps/MobileWeb/protocol/package.json protocol/package.json
COPY --from=build /app/Apps/MobileWeb/protocol/dist protocol/dist
COPY --from=build /app/Apps/MobileWeb/relay/package.json relay/package.json
COPY --from=build /app/Apps/MobileWeb/relay/dist relay/dist
COPY --from=build /app/Apps/MobileWeb/web/dist web/dist

USER node
EXPOSE 8787
CMD ["node", "relay/dist/index.js"]
