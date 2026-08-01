/**
 * AML Hook demo API — TypeScript + in-memory ledger (no database).
 *
 * MOCK: wallet balances, P2P hops, pool swap settlement, COA scoring (no LLM/vendors).
 * REAL (optional): when `.env.local` has ORACLE_RPC_URL + COMPLIANCE_ORACLE_ADDRESS +
 * KEEPER_PRIVATE_KEY, the keeper writes `updateScore` txs and quotes can read on-chain scores.
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
  app.log.info(`AML Hook demo API listening on http://localhost:${PORT}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
