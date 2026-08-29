/**
 * HTTP routes for the AML Hook demo API.
 *
 * Front talks only here. Privileged txs (updateScore, observeSwap, recover)
 * leave from this process. Decision truth is AmlHook.previewSwap on Anvil.
 */

import type { FastifyInstance, FastifyReply } from "fastify";
import {
  chainHealth,
  clearPolicyKnobsCache,
  hydrateWallets,
  isChainUnavailable,
  isPriceFeedBound,
  listEscrows,
  mintEth,
  mintUsdc,
  readPolicyKnobs,
  recoverBlocked,
  requireChain,
  resolveCheckpoint2,
  seedBalances,
  setPriceFeedBound,
  settleObservedSwap,
  transferUsdc,
  warpSeconds,
} from "./chain/index.js";
import { buildCompliancePack, buildSwapQuote } from "./compliance.js";
import { applyHopContamination } from "./ledger.js";
import {
  catchUpKeeper,
  ensureOracleEvaluation,
  getPublisherStatus,
  keeperTickMs,
  listOracleEvaluations,
  listScorePublishes,
  ofacHealth,
  reevaluateAfterBlock,
  reevaluateAfterSwap,
  reevaluateAfterTransfer,
  resetOracle,
  walletKeeperPending,
} from "./oracle/index.js";
import { anthropicModel, isLiveCoaEnabled } from "./oracle/liveOpinion.js";
import { isWalletId, walletScore } from "./scoring.js";
import {
  appendEvent,
  appendTransfer,
  getStore,
  getWallet,
  listEvents,
  listTransfers,
  resetStore,
  setWallets,
} from "./store.js";
import type { WalletId } from "./types.js";

const WALLET_IDS_HINT = "A, B, C, D, E, or F";

type TransferBody = {
  from?: string;
  to?: string;
  amountUsd?: number;
};

type SwapBody = {
  walletId?: string;
  amountUsd?: number;
};

function sendChainError(reply: FastifyReply, err: unknown) {
  if (isChainUnavailable(err)) {
    return reply.code(503).send({
      error: "deploy_local",
      message: err.message,
    });
  }
  const message = err instanceof Error ? err.message : String(err);
  return reply.code(500).send({ error: message });
}

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  app.get("/health", async () => {
    const chain = await chainHealth();
    const policy = await readPolicyKnobs(true);
    return {
      ok: chain.ok,
      mode: "anvil",
      oracle: "coa-agent",
      agent: {
        name: "Compliance Officer Agent",
        role: "AI AML analyst · Oracle Keeper",
        sources: "connected",
        status: "online",
        live: isLiveCoaEnabled(),
        model: isLiveCoaEnabled() ? anthropicModel() : null,
        score: isLiveCoaEnabled() ? "anthropic" : "skill",
        opinion: isLiveCoaEnabled() ? "anthropic" : "template",
      },
      ofac: ofacHealth(),
      keeperTickMs: keeperTickMs(),
      scoreSource: "onchain",
      publisher: getPublisherStatus(),
      chain,
      policy,
      wallets: ["A", "B", "C", "D", "E", "F"],
    };
  });

  app.get("/policy", async (_req, reply) => {
    try {
      const policy = await readPolicyKnobs(true);
      return { policy };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get("/wallets", async (_req, reply) => {
    try {
      const wallets = await hydrateWallets();
      const decorated = await Promise.all(
        wallets.map(async (w) => {
          const quote = await buildSwapQuote(w);
          return {
            ...w,
            score: quote.score,
            scoreSource: "onchain",
            decision: quote.decision,
            hookOutput: quote.hookOutput,
            appliedFeeBps: quote.feeBps,
            keeperPending: quote.keeperPending,
            latencyMitigation: quote.latencyMitigation,
            updatedAt: quote.isStale ? "stale" : "fresh",
          };
        }),
      );
      return { wallets: decorated };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get<{ Params: { id: string } }>("/wallets/:id", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    try {
      await hydrateWallets();
      const wallet = getWallet(id);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const quote = await buildSwapQuote(wallet);
      return {
        wallet: {
          ...wallet,
          score: quote.score,
          scoreSource: "onchain",
          decision: quote.decision,
          hookOutput: quote.hookOutput,
          appliedFeeBps: quote.feeBps,
          keeperPending: quote.keeperPending,
          latencyMitigation: quote.latencyMitigation,
        },
        quote,
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get<{ Params: { id: string }; Querystring: { amountUsd?: string } }>(
    "/wallets/:id/compliance",
    async (req, reply) => {
      const id = req.params.id.toUpperCase();
      if (!isWalletId(id)) {
        return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
      }
      try {
        await hydrateWallets();
        const wallet = getWallet(id);
        if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
        const amount = Number(req.query?.amountUsd);
        return await buildCompliancePack(
          wallet,
          Number.isFinite(amount) && amount > 0 ? amount : undefined,
        );
      } catch (err) {
        return sendChainError(reply, err);
      }
    },
  );

  app.get<{ Params: { id: string } }>("/wallets/:id/quote", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    try {
      await hydrateWallets();
      const wallet = getWallet(id);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const preferred = Number((req.query as { amountUsd?: string }).amountUsd ?? NaN);
      return await buildSwapQuote(
        wallet,
        Number.isFinite(preferred) ? preferred : undefined,
      );
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get<{ Params: { id: string } }>("/oracle/:id", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    return {
      ...(await ensureOracleEvaluation(id)),
      keeperPending: walletKeeperPending(id),
    };
  });

  app.post<{ Params: { id: string } }>("/oracle/:id/catch-up", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    try {
      await hydrateWallets();
      const wallet = getWallet(id);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const evaluation = await catchUpKeeper(id);
      await hydrateWallets();
      return {
        ok: true,
        keeperPending: false,
        scoreResult: evaluation.scoreResult,
        onChainPublish: evaluation.onChainPublish,
        compliance: await buildCompliancePack(getWallet(id)!),
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get("/oracle", async () => ({
    evaluations: listOracleEvaluations(),
  }));

  app.get("/oracle/publishes", async () => ({
    publisher: getPublisherStatus(),
    publishes: listScorePublishes(),
  }));

  app.get("/transfers", async () => ({ transfers: listTransfers() }));

  app.post<{ Body: TransferBody }>("/transfers", async (req, reply) => {
    const fromRaw = String(req.body?.from ?? "").toUpperCase();
    const toRaw = String(req.body?.to ?? "").toUpperCase();
    const amountUsd = Number(req.body?.amountUsd);

    if (!isWalletId(fromRaw) || !isWalletId(toRaw)) {
      return reply.code(400).send({ error: `from/to must be ${WALLET_IDS_HINT}` });
    }
    if (fromRaw === "F" || toRaw === "F") {
      return reply.code(400).send({
        error: "Wallet F is an OFAC SDN subject — P2P is disabled. Use a pool swap to see SanctionHit.",
      });
    }
    if (!Number.isFinite(amountUsd) || amountUsd <= 0) {
      return reply.code(400).send({ error: "amountUsd must be a positive number" });
    }

    try {
      await hydrateWallets();
      const sender = getWallet(fromRaw);
      if (!sender || sender.usdc < amountUsd) {
        return reply.code(400).send({
          error: "Transfer failed — insufficient USDC or invalid route",
        });
      }

      const txHash = await transferUsdc(fromRaw, toRaw, amountUsd);
      setWallets(applyHopContamination(getStore().wallets, fromRaw, toRaw));
      const record = {
        id: txHash,
        from: fromRaw,
        to: toRaw,
        amountUsd: Math.round(amountUsd),
        at: new Date().toISOString(),
        resultingScore: walletScore(getWallet(toRaw)!),
        hopDistance: getWallet(toRaw)!.hopDistance ?? 0,
      };
      appendTransfer(record);

      const oracle = await reevaluateAfterTransfer(fromRaw, toRaw);
      const wallets = await hydrateWallets();

      return {
        transfer: record,
        wallets: wallets.map((w) => ({
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
        recipientCompliance: await buildCompliancePack(getWallet(toRaw)!),
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get("/events", async () => ({ events: listEvents() }));

  app.post<{ Body: SwapBody }>("/swaps", async (req, reply) => {
    const idRaw = String(req.body?.walletId ?? "").toUpperCase();
    if (!isWalletId(idRaw)) {
      return reply.code(400).send({ error: `walletId must be ${WALLET_IDS_HINT}` });
    }

    try {
      await hydrateWallets();
      const wallet = getWallet(idRaw);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });

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
          reason: quote.revertReason ?? "REVERT — previewSwap fail-closed",
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

      const settled = await settleObservedSwap({
        walletId: idRaw,
        usdc: quote.usdcIn,
        preview: { decision: quote.decision, feeBps: quote.feeBps },
      });

      appendEvent({
        id: settled.observeTx ?? `ev-${Date.now()}`,
        walletId: idRaw,
        address: wallet.address,
        score: quote.score,
        decision: quote.hookOutput,
        feeBps: quote.feeBps,
        amountUsd: quote.usdcIn,
        hopDistance: wallet.hopDistance,
        origin: wallet.originId ?? "—",
        at: new Date().toISOString(),
        kind: "SwapObserved",
      });

      const catchUp = walletKeeperPending(idRaw)
        ? await catchUpKeeper(idRaw)
        : null;
      const oracle = catchUp ?? (await reevaluateAfterSwap(idRaw));
      await hydrateWallets();
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
        observeTx: settled.observeTx,
        spendTx: settled.spendTx,
        escrowTx: settled.escrowTx,
        escrowId: settled.escrowId,
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
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Body: { seconds?: number } }>("/demo/elapse", async (req, reply) => {
    try {
      const seconds = Number(req.body?.seconds ?? 301);
      const now = await warpSeconds(Number.isFinite(seconds) ? seconds : 301);
      return { ok: true, now, elapsedSeconds: Number.isFinite(seconds) ? seconds : 301 };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{
    Body: { walletId?: string; token?: string; amount?: number };
  }>("/demo/mint", async (req, reply) => {
    const idRaw = String(req.body?.walletId ?? "").toUpperCase();
    const token = String(req.body?.token ?? "").toLowerCase();
    const amount = Number(req.body?.amount);
    if (!isWalletId(idRaw)) {
      return reply.code(400).send({ error: `walletId must be ${WALLET_IDS_HINT}` });
    }
    if (idRaw === "F") {
      return reply.code(400).send({
        error: "Wallet F is an OFAC SDN subject — mint is disabled.",
      });
    }
    if (token !== "usdc" && token !== "eth") {
      return reply.code(400).send({ error: "token must be usdc or eth" });
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      return reply.code(400).send({ error: "amount must be a positive number" });
    }
    try {
      await hydrateWallets();
      const wallet = getWallet(idRaw);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const txHash =
        token === "usdc"
          ? await mintUsdc(wallet.address as `0x${string}`, amount)
          : await mintEth(wallet.address as `0x${string}`, amount);
      const wallets = await hydrateWallets();
      return {
        ok: true,
        token,
        amount,
        txHash,
        wallets: wallets.map((w) => ({
          ...w,
          score: walletScore(w),
        })),
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Body: { bound?: boolean } }>("/demo/price-feed", async (req, reply) => {
    try {
      const bound = req.body?.bound !== false;
      await setPriceFeedBound(bound);
      return { ok: true, priceFeedBound: await isPriceFeedBound() };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.get("/escrow", async (_req, reply) => {
    try {
      const rows = await listEscrows();
      return { rows };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Params: { id: string }; Body: { illicit?: boolean } }>(
    "/escrow/:id/checkpoint2",
    async (req, reply) => {
      try {
        const id = Number(req.params.id);
        const hash = await resolveCheckpoint2(id);
        return { ok: true, txHash: hash, rows: await listEscrows() };
      } catch (err) {
        return sendChainError(reply, err);
      }
    },
  );

  app.post<{ Params: { id: string } }>("/escrow/:id/recover", async (req, reply) => {
    try {
      const id = Number(req.params.id);
      const hash = await recoverBlocked(id);
      return { ok: true, txHash: hash, rows: await listEscrows() };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post("/reset", async (_req, reply) => {
    try {
      await requireChain();
      clearPolicyKnobsCache();
      const store = resetStore();
      await seedBalances();
      await resetOracle();
      const wallets = await hydrateWallets();
      return {
        ok: true,
        wallets: wallets.map((w) => ({
          ...w,
          score: walletScore(w),
        })),
        transfers: store.transfers,
        events: store.events,
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });
}
