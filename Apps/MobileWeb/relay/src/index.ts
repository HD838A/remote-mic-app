import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRelayServer } from "./server.js";

const port = parsePort(process.env.PORT);
const host = process.env.HOST ?? "127.0.0.1";
const publicOrigin = process.env.PUBLIC_ORIGIN;
if (!publicOrigin) {
  throw new Error("PUBLIC_ORIGIN is required");
}

const currentDirectory = resolve(fileURLToPath(new URL(".", import.meta.url)));
const staticDirectory = process.env.STATIC_DIR
  ? resolve(process.env.STATIC_DIR)
  : resolve(currentDirectory, "../../../web/dist");
const relay = createRelayServer({ publicOrigin, staticDirectory });

relay.server.listen(port, host, () => {
  process.stdout.write(`${new Date().toISOString()} relay=listening port=${port}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void relay.close().finally(() => process.exit(0));
  });
}

function parsePort(value: string | undefined): number {
  const port = Number(value ?? "8787");
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("PORT must be a valid TCP port");
  }
  return port;
}
