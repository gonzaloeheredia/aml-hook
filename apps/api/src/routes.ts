/**
 * HTTP routes for the AML Hook demo API.
 *
 * Front talks only here. Wallets A–D are an in-memory guided demo.
 * Wallet E is the Sepolia / Uniswap path (faucet, pool, chain events).
 */

import type { FastifyInstance, FastifyReply } from "fastify";
import { getAddress, isAddress } from "viem";
import {
  chainHealth,
  clearPolicyKnobsCache,
  hydrateWallets,
  listOnChainSwapObserved,
  isChainUnavailable,
  isPriceFeedBound,
  listEscrows,
  mintEth,
  mintUsdc,
  readPolicyKnobs,
  recoverBlocked,
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
  setPriceFeedBound,
  settleObservedSwap,
  transferUsdc,
  warpSeconds,
  DEFAULT_POLICY_KNOBS,
  getPolicyKnobsSync,
  isBoundWalletE,
  isLocalAnvil,
} from "./chain/index.js";
import { buildCompliancePack, buildSwapQuote } from "./compliance.js";
import { isMockDemoWallet, withDeadline } from "./demoMode.js";
import { applyP2pTransfer, applyPoolSwap } from "./ledger.js";
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
import { resolveEventSource, selectEventTrail } from "./eventsQuery.js";
import { isWalletId, walletScore } from "./scoring.js";
import {
  appendEvent,
  appendTransfer,
  elapseDemo,
  getStore,
  getWallet,
  listEvents,
  listTransfers,
  listWallets,
  recordAfterSwap,
  resetStore,
  setLastKnownUsdc,
  setWalletEAddress,
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

  app.get("/policy", async () => {
    void readPolicyKnobs(true).catch(() => undefined);
    return { policy: getPolicyKnobsSync() ?? DEFAULT_POLICY_KNOBS };
  });

  app.get("/wallets", async (_req, reply) => {
    try {
      const wallets = await hydrateWallets();
      const decorated = await Promise.all(
        wallets.map(async (w) => {
          try {
            const quote = isMockDemoWallet(w.id)
              ? await buildSwapQuote(w)
              : await withDeadline(buildSwapQuote(w), 2_500);
            return {
              ...w,
              score: quote.score,
              scoreSource: isMockDemoWallet(w.id) ? "memory" : "onchain",
              decision: quote.decision,
              hookOutput: quote.hookOutput,
              appliedFeeBps: quote.feeBps,
              keeperPending: quote.keeperPending,
              latencyMitigation: quote.latencyMitigation,
              updatedAt: quote.isStale ? "stale" : "fresh",
            };
          } catch (err) {
            if (isMockDemoWallet(w.id)) throw err;
            return {
              ...w,
              score: 0,
              scoreSource: "unscored",
              decision: "fee_override" as const,
              hookOutput: "FEE_OVERRIDE" as const,
              appliedFeeBps: 300,
              keeperPending: false,
              latencyMitigation: "SCORE_NEVER_WRITTEN" as const,
              updatedAt: "stale",
            };
          }
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
      if (!isMockDemoWallet(id)) await hydrateWallets();
      const wallet = getWallet(id);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const quote = await buildSwapQuote(wallet);
      return {
        wallet: {
          ...wallet,
          score: quote.score,
          scoreSource: isMockDemoWallet(id) ? "memory" : "onchain",
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
        if (!isMockDemoWallet(id)) await hydrateWallets();
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
      if (!isMockDemoWallet(id)) await hydrateWallets();
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

  app.post<{ Params: { id: string } }>("/oracle/:id/after-swap", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    try {
      if (!isMockDemoWallet(id)) await hydrateWallets();
      const wallet = getWallet(id);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const evaluation = await reevaluateAfterSwap(id);
      if (!isMockDemoWallet(id)) await hydrateWallets();
      return {
        ok: true,
        scoreResult: evaluation.scoreResult,
        onChainPublish: evaluation.onChainPublish,
        compliance: await buildCompliancePack(getWallet(id)!),
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Params: { id: string } }>("/oracle/:id/catch-up", async (req, reply) => {
    const id = req.params.id.toUpperCase();
    if (!isWalletId(id)) {
      return reply.code(400).send({ error: `Wallet id must be ${WALLET_IDS_HINT}` });
    }
    try {
      if (!isMockDemoWallet(id)) await hydrateWallets();
      const wallet = getWallet(id);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      const evaluation = await catchUpKeeper(id);
      if (!isMockDemoWallet(id)) await hydrateWallets();
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
    if (fromRaw === "E" || toRaw === "E") {
      return reply.code(400).send({
        error: "Wallet E is the live Sepolia MetaMask account. It does not use A–D P2P.",
      });
    }

    try {
      const mockPath = isMockDemoWallet(fromRaw) || isMockDemoWallet(toRaw);
      if (!mockPath) await hydrateWallets();
      const sender = getWallet(fromRaw);
      if (!sender || sender.usdc < amountUsd) {
        return reply.code(400).send({
          error: "Transfer failed: insufficient USDC or invalid route",
        });
      }

      let transferId: string;
      if (mockPath) {
        const next = applyP2pTransfer(getStore().wallets, fromRaw, toRaw, amountUsd);
        if (!next) {
          return reply.code(400).send({
            error: "Transfer failed: insufficient USDC or invalid route",
          });
        }
        setWallets(next);
        transferId = `p2p-${Date.now()}-${fromRaw}${toRaw}`;
      } else {
        transferId = await transferUsdc(fromRaw, toRaw, amountUsd);
      }
      const record = {
        id: transferId,
        from: fromRaw,
        to: toRaw,
        amountUsd: Math.round(amountUsd),
        at: new Date().toISOString(),
        resultingScore: walletScore(getWallet(toRaw)!),
        hopDistance: getWallet(toRaw)!.hopDistance ?? 0,
      };
      appendTransfer(record);

      const oracle = await reevaluateAfterTransfer(fromRaw, toRaw);
      const wallets = mockPath ? listWallets() : await hydrateWallets();

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

  app.get<{ Querystring: { walletId?: string; source?: string; address?: string } }>(
    "/events",
    async (req) => {
      const walletId = String(req.query.walletId ?? "").toUpperCase();
      const source = resolveEventSource(
        walletId,
        String(req.query.source ?? ""),
      );
      const demo = listEvents();
      let chain = demo.filter((e) => e.source === "chain");
      if (source !== "demo") {
        try {
          chain = await listOnChainSwapObserved();
        } catch {
          chain = [];
        }
      }
      let events = selectEventTrail(demo, chain, walletId, source);
      const addressRaw = String(req.query.address ?? "").trim();
      if (addressRaw && isAddress(addressRaw)) {
        const addr = getAddress(addressRaw).toLowerCase();
        events = events.filter((e) => e.address.toLowerCase() === addr);
      }
      return { events };
    },
  );

  app.post<{ Body: SwapBody }>("/swaps", async (req, reply) => {
    const idRaw = String(req.body?.walletId ?? "").toUpperCase();
    if (!isWalletId(idRaw)) {
      return reply.code(400).send({ error: `walletId must be ${WALLET_IDS_HINT}` });
    }

    try {
      if (idRaw === "E") {
        return reply.code(400).send({
          error:
            "Wallet E swaps on Sepolia from the frontend (MetaMask → Universal Router)",
        });
      }
      if (!isMockDemoWallet(idRaw)) await hydrateWallets();
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
          source: "demo" as const,
        };
        appendEvent(event);
        void reevaluateAfterBlock(idRaw).catch((err) => {
          console.error("reevaluateAfterBlock:", err);
        });
        return {
          settled: false,
          reason: quote.revertReason ?? "REVERT: WalletBlocked",
          quote,
          wallet,
          event,
        };
      }

      if (!quote.canSettle) {
        return reply.code(400).send({
          error: "Insufficient USDC for swap",
          quote,
        });
      }

      if (isMockDemoWallet(idRaw)) {
        const next = applyPoolSwap(
          getStore().wallets,
          idRaw,
          quote.usdcIn,
          quote.feeBps,
          quote.decision,
        );
        if (!next) {
          return reply.code(400).send({
            error: "Insufficient USDC for swap",
            quote,
          });
        }
        setWallets(next);
        setLastKnownUsdc(idRaw, next[idRaw].usdc);
        recordAfterSwap(idRaw, quote.usdcIn);

        const event = {
          id: `ev-${Date.now()}`,
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
          source: "demo" as const,
        };
        appendEvent(event);

        if (walletKeeperPending(idRaw)) {
          void catchUpKeeper(idRaw).catch((err) => {
            console.error("catchUpKeeper:", err);
          });
        } else {
          void reevaluateAfterSwap(idRaw).catch((err) => {
            console.error("reevaluateAfterSwap:", err);
          });
        }
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
        };
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

      if (walletKeeperPending(idRaw)) {
        void catchUpKeeper(idRaw).catch((err) => {
          console.error("catchUpKeeper:", err);
        });
      } else {
        void reevaluateAfterSwap(idRaw).catch((err) => {
          console.error("reevaluateAfterSwap:", err);
        });
      }
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
      };
    } catch (err) {
      return sendChainError(reply, err);
    }
  });

  app.post<{ Body: { seconds?: number } }>("/demo/elapse", async (req) => {
    const seconds = Number(req.body?.seconds ?? 301);
    const elapsed = Number.isFinite(seconds) ? Math.max(0, seconds) : 301;
    const now = elapseDemo(elapsed * 1000);
    if (isLocalAnvil()) {
      try {
        await warpSeconds(elapsed);
      } catch {
        /* memory clock still advanced */
      }
    }
    return { ok: true, now, elapsedSeconds: elapsed };
  });

  app.post<{ Body: { address?: string } }>("/demo/wallet-e", async (req, reply) => {
    const addressRaw = String(req.body?.address ?? "").trim();
    if (!isAddress(addressRaw)) {
      return reply.code(400).send({ error: "address must be a 20-byte hex EOA" });
    }
    const address = getAddress(addressRaw);
    if (!isBoundWalletE(address)) {
      return reply.code(400).send({ error: "Wallet E must be the connected MetaMask EOA" });
    }
    setWalletEAddress(address);
    try {
      const wallets = await hydrateWallets();
      return { ok: true, address, wallets };
    } catch {
      return { ok: true, address, wallets: listWallets() };
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
      if (!isBoundWalletE(address)) {
        return reply.code(400).send({ error: "Wallet E must be the connected MetaMask EOA" });
      }
      try {
        setWalletEAddress(address);
        const usdcTx = await mintUsdc(address, FAUCET_USDC);
        const ethTx = await mintEth(address, FAUCET_ETH);
        await hydrateWallets();
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
      const wallet = getWallet(idRaw);
      if (!wallet) return reply.code(404).send({ error: "Wallet not found" });
      if (idRaw === "E" && !isBoundWalletE(wallet.address)) {
        return reply.code(400).send({
          error: "Connect MetaMask as Wallet E before minting to that walletId",
        });
      }

      if (isMockDemoWallet(idRaw)) {
        const next = { ...getStore().wallets };
        next[idRaw] = {
          ...wallet,
          usdc: token === "usdc" ? wallet.usdc + amount : wallet.usdc,
          eth: token === "eth" ? wallet.eth + amount : wallet.eth,
        };
        setWallets(next);
        return {
          ok: true,
          token,
          amount,
          txHash: `mem-mint-${Date.now()}`,
          wallets: listWallets().map((w) => ({
            ...w,
            score: walletScore(w),
          })),
        };
      }

      await hydrateWallets();
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

  app.post("/reset", async () => {
    clearPolicyKnobsCache();
    const store = resetStore();
    await resetOracle();
    return {
      ok: true,
      wallets: listWallets().map((w) => ({
        ...w,
        score: walletScore(w),
      })),
      transfers: store.transfers,
      events: store.events,
    };
  });
}
