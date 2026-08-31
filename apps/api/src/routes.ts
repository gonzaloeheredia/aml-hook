/**
 * HTTP routes for the AML Hook demo API.
 *
 * Front talks only here. Privileged txs (updateScore, observeSwap, recover)
 * leave from this process. Decision truth is AmlHook.previewSwap on Anvil.
 */

import type { FastifyInstance, FastifyReply } from "fastify";
import { getAddress, isAddress } from "viem";
import {
  chainHealth,
  clearPolicyKnobsCache,
  hydrateWallets,
  listOnChainSwapObserved,
  mergeEventTrails,
  isChainUnavailable,
  isPriceFeedBound,
  listEscrows,
  mintEth,
  mintUsdc,
  readPolicyKnobs,
  recoverBlocked,
  requireChain,
  compensationOverview,
  accrueFromEscrow,
  closeCompensationEpoch,
  claimCompensation,
  treasuryOverview,
  setTreasuryDestination,
  proposeTreasuryPayout,
  executeTreasuryPayout,
  cancelTreasuryPayout,
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

const FAUCET_USDC = 1_000;
const FAUCET_ETH = 1;

const WALLET_IDS_HINT = "A, B, C, D, or E";

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
    const chainId = Number(process.env.ORACLE_CHAIN_ID ?? 31337);
    return {
      ok: chain.ok,
      mode: chainId === 11155111 ? "sepolia" : "anvil",
      chainId,
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
      wallets: ["A", "B", "C", "D", "E"],
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
    if (!Number.isFinite(amountUsd) || amountUsd <= 0) {
      return reply.code(400).send({ error: "amountUsd must be a positive number" });
    }

    try {
      await hydrateWallets();
      const sender = getWallet(fromRaw);
      if (!sender || sender.usdc < amountUsd) {
        return reply.code(400).send({
          error: "Transfer failed: insufficient USDC or invalid route",
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

  app.get("/events", async () => {
    try {
      const chain = await listOnChainSwapObserved();
      return { events: mergeEventTrails(listEvents(), chain) };
    } catch {
      return { events: listEvents() };
    }
  });

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
        const event = {
          id: `ev-${Date.now()}`,
          walletId: idRaw,
          address: wallet.address,
          score: quote.score,
          decision: "REVERT" as const,
          feeBps: 0,
          amountUsd: quote.usdcIn,
          hopDistance: wallet.hopDistance,
          origin: wallet.originId ?? "A",
          at: new Date().toISOString(),
          kind: "WalletBlocked" as const,
        };
        appendEvent(event);
        const oracle = await reevaluateAfterBlock(idRaw);
        return {
          settled: false,
          reason: quote.revertReason ?? "REVERT: previewSwap fail-closed",
          quote,
          wallet,
          event,
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

      const event = {
        id: settled.observeTx ?? `ev-${Date.now()}`,
        walletId: idRaw,
        address: wallet.address,
        score: quote.score,
        decision: quote.hookOutput,
        feeBps: quote.feeBps,
        amountUsd: quote.usdcIn,
        hopDistance: wallet.hopDistance,
        origin: wallet.originId ?? "n/a",
        at: new Date().toISOString(),
        kind: "SwapObserved" as const,
        txHash: settled.observeTx ?? undefined,
        source: "demo" as const,
      };
      appendEvent(event);

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
        event,
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
    Body: { walletId?: string; address?: string; token?: string; amount?: number };
  }>("/demo/mint", async (req, reply) => {
    const addressRaw = String(req.body?.address ?? "").trim();
    const idRaw = String(req.body?.walletId ?? "").toUpperCase();

    if (addressRaw && idRaw) {
      return reply.code(400).send({
        error: "Pass address (faucet) or walletId (A–E demo). Do not pass both",
      });
    }

    if (addressRaw) {
      if (!isAddress(addressRaw)) {
        return reply.code(400).send({ error: "address must be a 20-byte hex EOA" });
      }
      const address = getAddress(addressRaw);
      try {
        const usdcTx = await mintUsdc(address, FAUCET_USDC);
        const ethTx = await mintEth(address, FAUCET_ETH);
        return {
          ok: true,
          faucet: true,
          address,
          usdc: FAUCET_USDC,
          eth: FAUCET_ETH,
          usdcTx,
          ethTx,
        };
      } catch (err) {
        return sendChainError(reply, err);
      }
    }

    const token = String(req.body?.token ?? "").toLowerCase();
    const amount = Number(req.body?.amount);
    if (!isWalletId(idRaw)) {
      return reply.code(400).send({
        error: `walletId must be ${WALLET_IDS_HINT}, or pass address for the faucet`,
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

  app.get<{ Querystring: { account?: string } }>("/compensation", async (req, reply) => {
    try {
      const account = req.query.account && isAddress(req.query.account)
        ? getAddress(req.query.account)
        : undefined;
      return await compensationOverview(account);
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Params: { id: string } }>("/compensation/accrue/:id", async (req, reply) => {
    try {
      const hash = await accrueFromEscrow(Number(req.params.id));
      return { ok: true, txHash: hash, ...(await compensationOverview()) };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post("/compensation/close-epoch", async (_req, reply) => {
    try {
      return { ok: true, ...(await closeCompensationEpoch()) };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Body: { epochId?: number; account?: string } }>(
    "/compensation/claim",
    async (req, reply) => {
      try {
        const epochId = Number(req.body?.epochId);
        const account = req.body?.account;
        if (!Number.isFinite(epochId) || !account || !isAddress(account)) {
          return reply.code(400).send({ error: "epochId and account required" });
        }
        const hash = await claimCompensation(epochId, getAddress(account));
        return { ok: true, txHash: hash, ...(await compensationOverview(getAddress(account))) };
      } catch (err) {
        return sendChainError(reply, err);
      }
    },
  );

  app.get("/treasury", async (_req, reply) => {
    try {
      return await treasuryOverview();
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Body: { dest?: string; allowed?: boolean } }>(
    "/treasury/destinations",
    async (req, reply) => {
      try {
        const dest = req.body?.dest;
        if (!dest || !isAddress(dest)) {
          return reply.code(400).send({ error: "dest required" });
        }
        const hash = await setTreasuryDestination(getAddress(dest), req.body?.allowed !== false);
        return { ok: true, txHash: hash, ...(await treasuryOverview()) };
      } catch (err) {
        return sendChainError(reply, err);
      }
    },
  );

  app.post<{
    Body: {
      account?: "LP_PRINCIPAL" | "ILLICIT_RISK_FEE";
      amountUsdc?: number;
      to?: string;
      memo?: string;
      escrowId?: number;
    };
  }>("/treasury/propose", async (req, reply) => {
    try {
      const account = req.body?.account === "LP_PRINCIPAL" ? "LP_PRINCIPAL" : "ILLICIT_RISK_FEE";
      const to = req.body?.to;
      if (!to || !isAddress(to)) return reply.code(400).send({ error: "to required" });
      const res = await proposeTreasuryPayout({
        account,
        amountUsdc: req.body?.amountUsdc,
        to,
        memo: req.body?.memo,
        escrowId: req.body?.escrowId,
      });
      return { ok: true, ...res, ...(await treasuryOverview()) };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Params: { id: string } }>("/treasury/:id/execute", async (req, reply) => {
    try {
      const hash = await executeTreasuryPayout(Number(req.params.id));
      return { ok: true, txHash: hash, ...(await treasuryOverview()) };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Params: { id: string } }>("/treasury/:id/cancel", async (req, reply) => {
    try {
      const hash = await cancelTreasuryPayout(Number(req.params.id));
      return { ok: true, txHash: hash, ...(await treasuryOverview()) };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

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
