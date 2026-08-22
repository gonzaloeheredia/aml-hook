/**
 * AML Hook demo API — TypeScript + in-memory ledger (no database).
 *
 * Adapter: Anvil is the ledger and the decision (previewSwap / observeSwap / FeeEscrow).
 * COA stays mock. Privileged txs leave from this process. No TypeScript policy fallback.
 *
 * Replaces frontend simWallets / applyTransfer / applyPoolSwap for server-side demo flows.
 */

import cors from "@fastify/cors";
import Fastify from "fastify";
import { loadEnvFiles } from "./loadEnv.js";
import { registerRoutes } from "./routes.js";

loadEnvFiles();

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
  app.log.info(`AML Hook demo API on http://localhost:${PORT} — Anvil is the ledger`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
