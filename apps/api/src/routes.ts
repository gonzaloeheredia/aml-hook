/**
 * HTTP routes for the AML Hook demo API.
 *
 * MOCK: ledger (wallets / transfers / simulated pool swaps), COA opinions.
 * REAL optional: keeper publishes + scoreSource=onchain reads ComplianceOracle.
 * Check GET /health → publisher.mode (`mock`|`rpc`) and scoreSource (`memory`|`onchain`).
 *
 * Wallet D: A→D defers keeper updateScore; D swap applies §3.8 inflow FEE_OVERRIDE 8%,
 * then catch-up publishes decay score ~65.
 */

import type { FastifyInstance } from "fastify";
import { buildCompliancePack, buildSwapQuote } from "./compliance.js";
import { applyPoolSwap, applyTransfer } from "./ledger.js";
import {
  catchUpKeeper,
  ensureOracleEvaluation,
  getPublisherStatus,
  listOracleEvaluations,
  listScorePublishes,
  reevaluateAfterBlock,
  reevaluateAfterSwap,
  reevaluateAfterTransfer,
  resetOracle,
  seedOracleAll,
  walletKeeperPending,
} from "./oracle/index.js";
import { isWalletId, resolveWalletRisk, walletScore } from "./scoring.js";
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
  setLastKnownUsdc,
  setWallets,
} from "./store.js";
import type { WalletId } from "./types.js";

const WALLET_IDS_HINT = "A, B, C, or D";

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
    wallets: ["A", "B", "C", "D"],
  }));

  /** Lists all wallets with live oracle score, decision, and applied fee. */
  app.get("/wallets", async () => {
    const wallets = await Promise.all(
      listWallets().map(async (w) => {
        const quote = await buildSwapQuote(w);
        const { score, source } = await resolveWalletRisk(w);
        return {
          ...w,
          score: quote.score,
          scoreSource: source,
          decision: quote.decision,
          hookOutput: quote.hookOutput,
          appliedFeeBps: quote.feeBps,
          keeperPending: quote.keeperPending,
          latencyMitigation: quote.latencyMitigation,
        };
      }),
    );
    return { wallets };
  });

  /** Returns one wallet (A–D) plus a current swap quote. */
  app.get<{ Params: { id: string } }>("/wallets/:id", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    const wallet = getWallet(id);
    if (!wallet) {
      return reply.code(404).send({ error: "Wallet not found" });
    }
    const quote = await buildSwapQuote(wallet);
    const { source } = await resolveWalletRisk(wallet);
    return {
      wallet: {
        ...wallet,
        score: quote.score,
        scoreSource: source,
        decision: quote.decision,
        hookOutput: quote.hookOutput,
        appliedFeeBps: quote.feeBps,
        keeperPending: quote.keeperPending,
        latencyMitigation: quote.latencyMitigation,
      },
      quote,
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
        return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
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
        return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
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
        return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
      }
      return {
        ...(await ensureOracleEvaluation(id)),
        keeperPending: walletKeeperPending(id),
      };
    },
  );

  /**
   * Keeper catch-up for a deferred publish (Wallet D after A→D latency window).
   * Writes decay score (~65 for 1-hop) so subsequent swaps use N-hop fees.
   */
  app.post<{ Params: { id: string } }>(
    "/oracle/:id/catch-up",
    async (req, reply) => {
      const id = req.params.id.toUpperCase();
      if (!isWalletId(id)) {
        return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
      }
      const wallet = getWallet(id);
      if (!wallet) {
        return reply.code(404).send({ error: "Wallet not found" });
      }
      const evaluation = await catchUpKeeper(id);
      return {
        ok: true,
        keeperPending: false,
        scoreResult: evaluation.scoreResult,
        onChainPublish: evaluation.onChainPublish,
        compliance: await buildCompliancePack(getWallet(id)!),
      };
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
   * reevaluates oracle scores for from/to (D recipient defers keeper),
   * returns recipient compliance.
   */
  app.post<{ Body: TransferBody }>("/transfers", async (req, reply) => {
    const fromRaw = String(req.body?.from ?? "").toUpperCase();
    const toRaw = String(req.body?.to ?? "").toUpperCase();
    const amountUsd = Number(req.body?.amountUsd);

    if (!isWalletId(fromRaw) || !isWalletId(toRaw)) {
      return reply.code(400).send({ error: `from/to must be ${WALLET_IDS_HINT}` });
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

    // Oracle COA + keeper publish — recipient D stays on stale score 0 until catch-up
    const oracle = await reevaluateAfterTransfer(fromRaw, toRaw);

    return {
      transfer: result.record,
      wallets: listWallets().map((w) => ({
        ...w,
        score: walletScore(w),
        keeperPending: walletKeeperPending(w.id),
      })),
      oracle: {
        from: oracle.from.scoreResult,
        to: oracle.to?.scoreResult ?? null,
        keeperPending: oracle.keeperPending,
      },
      onChainPublish: {
        from: oracle.from.onChainPublish,
        to: oracle.to?.onChainPublish ?? null,
      },
      keeperPending: oracle.keeperPending,
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
   * Wallet D with pending keeper: afterSwap also runs catch-up → score ~65.
   */
  app.post<{ Body: SwapBody }>("/swaps", async (req, reply) => {
    const idRaw = String(req.body?.walletId ?? "").toUpperCase();
    if (!isWalletId(idRaw)) {
      return reply.code(400).send({ error: `walletId must be ${WALLET_IDS_HINT}` });
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
    setLastKnownUsdc(idRaw, updated.usdc);

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

    // Deferred keeper catch-up for Wallet D after the latency swap.
    const catchUp = walletKeeperPending(idRaw)
      ? await catchUpKeeper(idRaw)
      : null;
    const oracle = catchUp ?? (await reevaluateAfterSwap(idRaw));

    const after = getWallet(idRaw)!;

    return {
      settled: true,
      quote,
      wallet: {
        ...after,
        score: walletScore(after),
        keeperPending: walletKeeperPending(idRaw),
      },
      ethReceived: quote.ethOut,
      oracle: oracle.scoreResult,
      onChainPublish: oracle.onChainPublish,
      keeperCatchUp: catchUp
        ? {
            published: true,
            score: catchUp.scoreResult.finalScore,
            feeBps: catchUp.scoreResult.recommendedFeeBps,
          }
        : null,
      compliance: await buildCompliancePack(after),
    };
  });

  /** Reseeds A–D, clears history, and reseeds oracle scores. */
  app.post("/reset", async () => {
    const store = resetStore();
    await resetOracle();
    return {
      ok: true,
      wallets: Object.values(store.wallets).map((w) => ({
        ...w,
        score: walletScore(w),
        keeperPending: false,
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
