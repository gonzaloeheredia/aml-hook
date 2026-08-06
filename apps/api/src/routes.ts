/**
 * HTTP routes for the AML Hook demo API.
 *
 * MOCK: ledger (wallets / transfers / simulated pool swaps), COA opinions.
 * REAL optional: keeper publishes + scoreSource=onchain reads ComplianceOracle.
 * Check GET /health → publisher.mode (`mock`|`rpc`) and scoreSource (`memory`|`onchain`).
 */

import type { FastifyInstance } from "fastify";
import { buildCompliancePack, buildSwapQuote } from "./compliance.js";
import { applyPoolSwap, applyTransfer } from "./ledger.js";
import {
  ensureOracleEvaluation,
  getPublisherStatus,
  listOracleEvaluations,
  listScorePublishes,
  reevaluateAfterBlock,
  reevaluateAfterSwap,
  reevaluateAfterTransfer,
  resetOracle,
  seedOracleAll,
} from "./oracle/index.js";
import {
  decisionFromScore,
  isWalletId,
  resolveWalletRisk,
  toHookOutput,
  walletScore,
} from "./scoring.js";
import { preferOnChainScore } from "./oracle/onchainReader.js";
import {
  appendEvent,
  appendTransfer,
  getStore,
  getWallet,
  listEvents,
  listTransfers,
  listWallets,
  resetStore,
  setWallets,
} from "./store.js";
import type { WalletId } from "./types.js";

/** Body shape for POST /transfers. */
type TransferBody = {
  from?: string;
  to?: string;
  amountUsd?: number;
};

/** Body shape for POST /swaps. */
type SwapBody = {
  walletId?: string;
  amountUsd?: number;
};

/**
 * Registers all demo API routes on the Fastify instance
 * (wallets, transfers, swaps, compliance, oracle, reset).
 */
export async function registerRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Health — ledger is process-local; COA runs as a connected virtual agent.
   */
  app.get("/health", async () => ({
    ok: true,
    mode: "in-memory",
    oracle: "coa-agent",
    agent: {
      name: "Compliance Officer Agent",
      role: "AI AML analyst · Oracle Keeper",
      sources: "connected",
      status: "online",
    },
    scoreSource: preferOnChainScore() ? "onchain" : "memory",
    publisher: getPublisherStatus(),
    persistence: "none — state resets on process restart",
  }));

  /** Lists all wallets with live oracle score, decision, and applied fee. */
  app.get("/wallets", async () => {
    const wallets = await Promise.all(
      listWallets().map(async (w) => {
        const { score, feeBps, source } = await resolveWalletRisk(w);
        const decision = decisionFromScore(score);
        return {
          ...w,
          score,
          scoreSource: source,
          decision,
          hookOutput: toHookOutput(decision),
          appliedFeeBps: feeBps,
        };
      }),
    );
    return { wallets };
  });

  /** Returns one wallet (A/B/C) plus a current swap quote. */
  app.get<{ Params: { id: string } }>("/wallets/:id", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: "Wallet id must be A, B, or C" });
    }
    const wallet = getWallet(id);
    if (!wallet) {
      return reply.code(404).send({ error: "Wallet not found" });
    }
    const { score, feeBps, source } = await resolveWalletRisk(wallet);
    const decision = decisionFromScore(score);
    return {
      wallet: {
        ...wallet,
        score,
        scoreSource: source,
        decision,
        hookOutput: toHookOutput(decision),
        appliedFeeBps: feeBps,
      },
      quote: await buildSwapQuote(wallet),
    };
  });

  /**
   * Returns the live compliance opinion for a wallet
   * (oracle COA → technical opinion + SAR annex + decision record).
   */
  app.get<{ Params: { id: string } }>(
    "/wallets/:id/compliance",
    async (req, reply) => {
      const id = req.params.id.toUpperCase();
      if (!isWalletId(id)) {
        return reply.code(400).send({ error: "Wallet id must be A, B, or C" });
      }
      const wallet = getWallet(id);
      if (!wallet) {
        return reply.code(404).send({ error: "Wallet not found" });
      }
      return await buildCompliancePack(wallet);
    },
  );

  /** Preview a USDC→ETH swap quote without mutating balances. */
  app.get<{ Params: { id: string } }>(
    "/wallets/:id/quote",
    async (req, reply) => {
      const id = req.params.id.toUpperCase();
      if (!isWalletId(id)) {
        return reply.code(400).send({ error: "Wallet id must be A, B, or C" });
      }
      const wallet = getWallet(id);
      if (!wallet) {
        return reply.code(404).send({ error: "Wallet not found" });
      }
      const preferred = Number(
        (req.query as { amountUsd?: string }).amountUsd ?? NaN,
      );
      return await buildSwapQuote(
        wallet,
        Number.isFinite(preferred) ? preferred : undefined,
      );
    },
  );

  /** Cached oracle ScoreResult + opinion for a wallet. */
  app.get<{ Params: { id: string } }>(
    "/oracle/:id",
    async (req, reply) => {
      const id = req.params.id.toUpperCase();
      if (!isWalletId(id)) {
        return reply.code(400).send({ error: "Wallet id must be A, B, or C" });
      }
      return await ensureOracleEvaluation(id);
    },
  );

  /** Lists all cached oracle evaluations. */
  app.get("/oracle", async () => ({
    evaluations: listOracleEvaluations(),
  }));

  /** Keeper → ComplianceOracle.updateScore publish trail (mock or rpc). */
  app.get("/oracle/publishes", async () => ({
    publisher: getPublisherStatus(),
    publishes: listScorePublishes(),
  }));

  /** Returns the P2P transfer history. */
  app.get("/transfers", async () => ({ transfers: listTransfers() }));

  /**
   * Executes a P2P USDC transfer, updates hop contamination,
   * reevaluates oracle scores for from/to, returns recipient compliance.
   */
  app.post<{ Body: TransferBody }>("/transfers", async (req, reply) => {
    const fromRaw = String(req.body?.from ?? "").toUpperCase();
    const toRaw = String(req.body?.to ?? "").toUpperCase();
    const amountUsd = Number(req.body?.amountUsd);

    if (!isWalletId(fromRaw) || !isWalletId(toRaw)) {
      return reply.code(400).send({ error: "from/to must be A, B, or C" });
    }
    if (!Number.isFinite(amountUsd) || amountUsd <= 0) {
      return reply.code(400).send({ error: "amountUsd must be a positive number" });
    }

    const result = applyTransfer(getStore().wallets, fromRaw, toRaw, amountUsd);
    if (!result) {
      return reply.code(400).send({
        error: "Transfer failed — insufficient USDC or invalid route",
      });
    }

    setWallets(result.wallets);
    appendTransfer(result.record);

    // Oracle COA + keeper publish (ComplianceOracle.updateScore) before next swap
    const oracle = await reevaluateAfterTransfer(fromRaw, toRaw);

    return {
      transfer: result.record,
      wallets: listWallets().map((w) => ({
        ...w,
        score: walletScore(w),
      })),
      oracle: {
        from: oracle.from.scoreResult,
        to: oracle.to.scoreResult,
      },
      onChainPublish: {
        from: oracle.from.onChainPublish,
        to: oracle.to.onChainPublish,
      },
      recipientCompliance: await buildCompliancePack(
        result.wallets[toRaw as WalletId],
      ),
    };
  });

  /** Returns the simulated hook event trail. */
  app.get("/events", async () => ({ events: listEvents() }));

  /**
   * Settles a pool swap against the in-memory ledger.
   * REVERT → WalletBlocked + oracle refresh.
   * ALLOW / FEE_OVERRIDE → afterSwap SwapObserved + oracle reevaluate for next beforeSwap.
   */
  app.post<{ Body: SwapBody }>("/swaps", async (req, reply) => {
    const idRaw = String(req.body?.walletId ?? "").toUpperCase();
    if (!isWalletId(idRaw)) {
      return reply.code(400).send({ error: "walletId must be A, B, or C" });
    }
    const wallet = getWallet(idRaw);
    if (!wallet) {
      return reply.code(404).send({ error: "Wallet not found" });
    }

    const preferred = Number(req.body?.amountUsd);
    const quote = await buildSwapQuote(
      wallet,
      Number.isFinite(preferred) ? preferred : undefined,
    );

    if (quote.decision === "block") {
      appendEvent({
        id: `ev-${Date.now()}`,
        walletId: idRaw,
        address: wallet.address,
        score: quote.score,
        decision: "REVERT",
        feeBps: 0,
        amountUsd: quote.usdcIn,
        hopDistance: wallet.hopDistance,
        origin: wallet.originId ?? "A",
        at: new Date().toISOString(),
        kind: "WalletBlocked",
      });
      const oracle = await reevaluateAfterBlock(idRaw);
      return {
        settled: false,
        reason: "REVERT — beforeSwap fail-closed",
        quote,
        wallet,
        oracle: oracle.scoreResult,
        onChainPublish: oracle.onChainPublish,
        compliance: await buildCompliancePack(wallet),
      };
    }

    if (!quote.canSettle) {
      return reply.code(400).send({
        error: "Insufficient USDC for swap",
        quote,
      });
    }

    const next = applyPoolSwap(
      getStore().wallets,
      idRaw,
      quote.usdcIn,
      quote.feeBps,
      quote.decision,
    );
    if (!next) {
      return reply.code(400).send({ error: "Swap settlement failed", quote });
    }

    setWallets(next);
    const updated = next[idRaw];
    appendEvent({
      id: `ev-${Date.now()}`,
      walletId: idRaw,
      address: updated.address,
      score: quote.score,
      decision: quote.hookOutput,
      feeBps: quote.feeBps,
      amountUsd: quote.usdcIn,
      hopDistance: updated.hopDistance,
      origin: updated.originId ?? "—",
      at: new Date().toISOString(),
      kind: "SwapObserved",
    });

    // afterSwap → oracle COA + keeper publish before next beforeSwap
    const oracle = await reevaluateAfterSwap(idRaw);

    return {
      settled: true,
      quote,
      wallet: {
        ...updated,
        score: walletScore(updated),
      },
      ethReceived: quote.ethOut,
      oracle: oracle.scoreResult,
      onChainPublish: oracle.onChainPublish,
      compliance: await buildCompliancePack(updated),
    };
  });

  /** Reseeds A/B/C, clears history, and reseeds oracle scores. */
  app.post("/reset", async () => {
    const store = resetStore();
    await resetOracle();
    return {
      ok: true,
      wallets: Object.values(store.wallets).map((w) => ({
        ...w,
        score: walletScore(w),
      })),
      transfers: store.transfers,
      events: store.events,
      oracle: listOracleEvaluations().map((e) => e.scoreResult),
      publisher: getPublisherStatus(),
    };
  });

  // Ensure baseline oracle scores (+ mock publishes) exist when routes load
  await seedOracleAll();
}
