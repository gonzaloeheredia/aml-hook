/**
 * AML Hook demo API — TypeScript + in-memory store (no database).
 *
 * Replaces frontend simWallets / applyTransfer / applyPoolSwap / withHopOverlay
 * for server-side demo flows.
 */

import cors from "@fastify/cors";
import Fastify from "fastify";
import { registerRoutes } from "./routes.js";

const PORT = Number(process.env.PORT ?? 4000);
const HOST = process.env.HOST ?? "0.0.0.0";

/**
 * Boots Fastify with CORS, registers demo routes, and listens on PORT.
 */
async function main() {
  const app = Fastify({
    logger: true,
  });

  await app.register(cors, {
    origin: true,
  });

  await registerRoutes(app);

  await app.listen({ port: PORT, host: HOST });
  app.log.info(`AML Hook demo API listening on http://localhost:${PORT}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
