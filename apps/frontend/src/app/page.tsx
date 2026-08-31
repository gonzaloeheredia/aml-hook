"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AmlStats, LegalOpinion } from "@/components/AuditReport";
import { ConnectModal } from "@/components/ConnectModal";
import { FeeSummary } from "@/components/FeeSummary";
import { FlowSimulator } from "@/components/FlowSimulator";
import { MetaMaskPanel } from "@/components/MetaMaskPanel";
import { NavBar, type AppView } from "@/components/NavBar";
import { UseOfCaseView } from "@/components/UseOfCaseView";
import { WhitepaperView } from "@/components/WhitepaperView";
import { OnChainAccumulator } from "@/components/OnChainAccumulator";
import { StageMorph } from "@/components/StageMorph";
import { DEMO_STAGES, StageRail, type DemoStage } from "@/components/StageRail";
import { StageContinueFab } from "@/components/StageContinueFab";
import { StageSideNav } from "@/components/StageSideNav";
import { SwapWidget } from "@/components/SwapWidget";
import { walletTone } from "@/components/WalletTag";
import { DEMO_CASES, type DemoCase, type DemoCaseId } from "@/data/cases";
import {
  ApiError,
  fetchCompliance,
  fetchEvents,
  fetchHealth,
  fetchPolicy,
  fetchTransfers,
  fetchWallets,
  postSwap,
  postTransfer,
  postReset,
  postDemoElapse,
  postBindWalletE,
  postOracleAfterSwap,
  postDemoFaucet,
  postDemoMint,
  toSimWallet,
  walletsRecord,
  type ApiCompliancePack,
} from "@/lib/api";
import {
  EMPTY_STATS,
  EMPTY_UNLOCK,
  STAGE_ORDER,
  clearDemoSession,
  loadDemoSession,
  mergeSimWallets,
  mergeTransfers,
  preferFresherCompliance,
  railwayLooksStale,
  saveDemoSession,
  type DemoSessionSnapshot,
  type SwapStats,
} from "@/lib/demoSession";
import {
  caseIdForSimWallet,
  ethOutFromSwap,
  initialSimWallets,
  isBoundWalletE,
  preserveLiveE,
  setPolicyKnobs,
  setPriceFeedBound,
  withSepoliaWalletE,
  type SimWallet,
  type SimWalletId,
} from "@/lib/hopScoring";
import {
  buildHookChainEvent,
  hookEventFromApi,
  mergeHookEvents,
  type HookChainEvent,
} from "@/lib/hookEvents";
import { applyLiveCaseCopy } from "@/lib/liveCaseCopy";
import {
  hookEventFromSepolia,
  listSepoliaSwapObserved,
  swapObservedFromReceipt,
  swapObservedFromTx,
} from "@/lib/sepoliaSwapObserved";
import { connectSepoliaAccount, readSepoliaBalances } from "@/lib/sepoliaWallet";
import { swapUsdcForWeth } from "@/lib/sepoliaSwap";
import { withComplianceOverlay } from "@/lib/withComplianceOverlay";
import type { Address } from "viem";

/**
 * Demo page: guided stages with horizontal slides.
 * Get started opens Hook. Later modules advance only on click (rail, floating control, chevron, or half-screen).
 * Event has a Back to Swap control; ledger balances persist until Restart data.
 */
type ApiStatus = "connecting" | "online" | "offline";

/**
 * Returns the later of two stages in the guided sequence.
 */
function maxStage(a: DemoStage, b: DemoStage): DemoStage {
  return STAGE_ORDER.indexOf(a) >= STAGE_ORDER.indexOf(b) ? a : b;
}

function nextStageLabel(stage: DemoStage): string | null {
  const next = STAGE_ORDER[STAGE_ORDER.indexOf(stage) + 1];
  if (!next) return null;
  return DEMO_STAGES.find((s) => s.id === next)?.label ?? next;
}

function eventsForWallet(
  events: HookChainEvent[],
  walletId: DemoCaseId,
  liveAddress: string | null,
): HookChainEvent[] {
  if (walletId === "E" && liveAddress) {
    const addr = liveAddress.toLowerCase();
    return events.filter((e) => e.address.toLowerCase() === addr);
  }
  return events.filter((e) => e.walletId === walletId);
}

/**
 * Hook / Fees / Opinion for E follow the last Sepolia SwapObserved, not the static template.
 */
function overlayFromSepoliaEvent(
  demoCase: DemoCase,
  event: HookChainEvent,
): DemoCase {
  const decision: DemoCase["decision"] =
    event.decision === "REVERT"
      ? "block"
      : event.decision === "FEE_OVERRIDE"
        ? "fee_override"
        : "allow";
  const flowPath = decision;
  const decisionLabel =
    decision === "block"
      ? "Block"
      : decision === "fee_override"
        ? "Fee override"
        : "Allow";
  return {
    ...demoCase,
    score: event.score,
    decision,
    decisionLabel,
    appliedFeeBps: event.feeBps,
    feeMultiplier:
      demoCase.baseFeeBps > 0 ? event.feeBps / demoCase.baseFeeBps : 0,
    flowPath,
    activity: {
      ...demoCase.activity,
      hopDistance: event.hopDistance,
      origin: event.origin,
      txCount: Math.max(demoCase.activity.txCount, 1),
    },
    agent: {
      ...demoCase.agent,
      hookOutput: event.decision,
    },
  };
}

function statsFromEvents(
  events: HookChainEvent[],
  walletId: DemoCaseId,
): SwapStats {
  const settled = events.filter(
    (e) => e.walletId === walletId && e.eventName === "SwapObserved",
  );
  let tradedUsd = 0;
  let tradedEth = 0;
  for (const e of settled) {
    tradedUsd += e.amountUsd;
    tradedEth += ethOutFromSwap(e.amountUsd, e.feeBps);
  }
  return { count: settled.length, tradedUsd, tradedEth };
}

function mergeStats(a: SwapStats, b: SwapStats): SwapStats {
  return {
    count: Math.max(a.count, b.count),
    tradedUsd: Math.max(a.tradedUsd, b.tradedUsd),
    tradedEth: Math.max(a.tradedEth, b.tradedEth),
  };
}

export default function HomePage() {
  const [caseId, setCaseId] = useState<DemoCaseId>("A");
  const [modalOpen, setModalOpen] = useState(false);
  const [metaMaskOpen, setMetaMaskOpen] = useState(false);
  const [connected, setConnected] = useState(false);
  const [address, setAddress] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [swapStats, setSwapStats] = useState(EMPTY_STATS);

  const [simWallets, setSimWallets] = useState<Record<SimWalletId, SimWallet>>(
    () => initialSimWallets(),
  );
  const [simActiveId, setSimActiveId] = useState<SimWalletId>("A");
  const [transfers, setTransfers] = useState<
    DemoSessionSnapshot["transfers"]
  >([]);
  const [chainEvents, setChainEvents] = useState<HookChainEvent[]>([]);
  const [, setAuditRevealKey] = useState(0);

  const [stage, setStage] = useState<DemoStage>("swap");
  const [slideDir, setSlideDir] = useState<1 | -1>(1);
  const [slideSwift, setSlideSwift] = useState(false);
  const [unlockByWallet, setUnlockByWallet] = useState(EMPTY_UNLOCK);
  const unlockedThrough = unlockByWallet[caseId];

  const [appView, setAppView] = useState<AppView>("hook");
  const [apiStatus, setApiStatus] = useState<ApiStatus>("connecting");
  const [apiError, setApiError] = useState<string | null>(null);
  const [faucetBusy, setFaucetBusy] = useState(false);
  const [swapBusy, setSwapBusy] = useState(false);
  const [swapError, setSwapError] = useState<string | null>(null);
  const [connectError, setConnectError] = useState<string | null>(null);
  const [liveEAddress, setLiveEAddress] = useState<string | null>(null);
  const [nativeEth, setNativeEth] = useState<number | null>(null);
  const [compliance, setCompliance] = useState<ApiCompliancePack | null>(
    null,
  );
  const [complianceByWallet, setComplianceByWallet] = useState<
    Partial<Record<DemoCaseId, ApiCompliancePack>>
  >({});
  const [swapAmountUsd, setSwapAmountUsd] = useState(
    DEMO_CASES.A.activity.amountUsd,
  );
  const [demoTick, setDemoTick] = useState(0);
  const [sessionReady, setSessionReady] = useState(false);

  const wheelLockRef = useRef(false);
  const stageRef = useRef(stage);
  const unlockedRef = useRef(unlockedThrough);
  const visitedRef = useRef<Set<DemoStage>>(new Set<DemoStage>(["swap"]));
  const persistPausedRef = useRef(true);
  const liveEAddressRef = useRef<string | null>(null);
  const complianceByWalletRef = useRef(complianceByWallet);
  const sessionRef = useRef<DemoSessionSnapshot>({
    v: 1,
    simWallets,
    transfers,
    chainEvents,
    swapStats,
    complianceByWallet,
    unlockByWallet,
    caseId,
    connected,
    swapAmountUsd,
    stage,
  });
  stageRef.current = stage;
  unlockedRef.current = unlockedThrough;
  complianceByWalletRef.current = complianceByWallet;
  sessionRef.current = {
    v: 1,
    simWallets,
    transfers,
    chainEvents,
    swapStats,
    complianceByWallet,
    unlockByWallet,
    caseId,
    connected,
    swapAmountUsd,
    stage,
  };

  const trailEvents = eventsForWallet(chainEvents, caseId, liveEAddress);
  const liveStats =
    caseId === "E"
      ? mergeStats(swapStats.E, statsFromEvents(trailEvents, "E"))
      : swapStats[caseId];

  const writeSession = useCallback((patch?: Partial<DemoSessionSnapshot>) => {
    const next: DemoSessionSnapshot = {
      ...sessionRef.current,
      ...patch,
      v: 1,
    };
    sessionRef.current = next;
    if (persistPausedRef.current) return;
    saveDemoSession(next);
  }, []);

  /**
   * Hydrate from sessionStorage before paint so API refresh can merge, not clobber.
   */
  useLayoutEffect(() => {
    const snap = loadDemoSession();
    if (snap) {
      setCaseId(snap.caseId);
      setSimActiveId(snap.caseId);
      setConnected(snap.connected);
      setSimWallets(snap.simWallets);
      setTransfers(snap.transfers);
      setChainEvents(snap.chainEvents);
      setSwapStats(snap.swapStats);
      setUnlockByWallet(snap.unlockByWallet);
      setComplianceByWallet(snap.complianceByWallet);
      const pack = snap.complianceByWallet[snap.caseId];
      if (pack) setCompliance(pack);
      if (snap.connected) {
        const restored = snap.simWallets[snap.caseId]?.address ?? null;
        if (snap.caseId === "E" && !isBoundWalletE(restored)) {
          setConnected(false);
          setAddress(null);
        } else {
          setAddress(restored);
          if (snap.caseId === "E" && restored) {
            liveEAddressRef.current = restored;
            setLiveEAddress(restored);
          }
        }
      }
      if (snap.swapAmountUsd > 0) setSwapAmountUsd(snap.swapAmountUsd);
      setStage(snap.stage);
      const through = snap.unlockByWallet[snap.caseId];
      const idx = STAGE_ORDER.indexOf(through);
      visitedRef.current = new Set(STAGE_ORDER.slice(0, Math.max(idx, 0) + 1));
      visitedRef.current.add(snap.stage);
      sessionRef.current = snap;
    }
    persistPausedRef.current = false;
    setSessionReady(true);
  }, []);

  useEffect(() => {
    if (!sessionReady) return;
    writeSession();
  }, [
    sessionReady,
    writeSession,
    simWallets,
    transfers,
    chainEvents,
    swapStats,
    complianceByWallet,
    unlockByWallet,
    caseId,
    connected,
    swapAmountUsd,
    stage,
  ]);

  const bumpUnlock = useCallback((next: DemoStage, wallet: DemoCaseId) => {
    setUnlockByWallet((prev) => ({
      ...prev,
      [wallet]: maxStage(prev[wallet], next),
    }));
  }, []);
  const nextModule = nextStageLabel(stage);
  const nextModuleOpen =
    nextModule != null &&
    STAGE_ORDER.indexOf(stage) + 1 <= STAGE_ORDER.indexOf(unlockedThrough);
  const showContinueFab =
    Boolean(nextModule && nextModuleOpen) && stage !== "swap";
  const baseCase = useMemo(() => {
    const raw = DEMO_CASES[caseId];
    return {
      ...raw,
      activity: { ...raw.activity, amountUsd: swapAmountUsd },
    };
  }, [caseId, swapAmountUsd]);

  /** Decision comes from the API (hook previewSwap). Copy/chips follow officer knobs. */
  const demoCase = useMemo(() => {
    const overlaid =
      compliance && compliance.walletId === caseId
        ? withComplianceOverlay(baseCase, compliance)
        : baseCase;
    const withCopy = applyLiveCaseCopy(overlaid);
    if (caseId !== "E") return withCopy;
    const last = [...trailEvents]
      .reverse()
      .find(
        (e) =>
          e.eventName === "SwapObserved" || e.eventName === "WalletBlocked",
      );
    return last ? overlayFromSepoliaEvent(withCopy, last) : withCopy;
  }, [baseCase, caseId, compliance, demoTick, trailEvents]);

  /**
   * Sets the slide direction from the current stage, then changes stage.
   * First visit forward keeps the guided pace; back or a revisit is swift.
   */
  const pointStage = useCallback((next: DemoStage) => {
    const cur = stageRef.current;
    if (next !== cur) {
      const goingBack =
        STAGE_ORDER.indexOf(next) < STAGE_ORDER.indexOf(cur);
      const revisit = visitedRef.current.has(next);
      setSlideDir(goingBack ? -1 : 1);
      setSlideSwift(goingBack || revisit);
      visitedRef.current.add(next);
    }
    setStage(next);
  }, []);

  /**
   * Advances the guided stage and expands the unlock frontier.
   */
  const goToStage = useCallback(
    (next: DemoStage, wallet: DemoCaseId = caseId) => {
      pointStage(next);
      bumpUnlock(next, wallet);
    },
    [bumpUnlock, caseId, pointStage],
  );

  /**
   * Loads wallets, transfers, and events from the backend.
   * On-chain USDC/ETH win. Events / transfers / hop overlay are merged so a
   * Railway process restart cannot wipe the in-tab walkthrough.
   */
  const refreshLedger = useCallback(async () => {
    const live = liveEAddressRef.current;
    const [walletsRes, transfersRes, eventsRes] = await Promise.all([
      fetchWallets(),
      fetchTransfers(),
      fetchEvents(
        caseId,
        caseId === "E" ? live ?? undefined : undefined,
        caseId === "E" ? "chain" : "demo",
      ),
    ]);
    const apiWallets = walletsRecord(walletsRes.wallets);
    const apiEvents = eventsRes.events.map((ev, i) =>
      hookEventFromApi(ev, i + 1),
    );
    const apiTransfers = transfersRes.transfers;
    const prev = sessionRef.current;
    const stale = railwayLooksStale(
      prev.chainEvents,
      apiEvents,
      prev.transfers,
      apiTransfers,
    );
    const mergedWallets = mergeSimWallets(prev.simWallets, apiWallets, stale);
    const mergedTransfers = mergeTransfers(prev.transfers, apiTransfers);
    const mergedEvents = mergeHookEvents(prev.chainEvents, apiEvents);
    let nextWallets = mergedWallets;
    if (live && isBoundWalletE(live)) {
      try {
        const bal = await readSepoliaBalances(live as Address);
        setNativeEth(bal.nativeEth);
        nextWallets = withSepoliaWalletE(mergedWallets, {
          address: bal.address,
          usdc: bal.usdc,
          eth: bal.weth,
        });
      } catch {
        setNativeEth(null);
        nextWallets = withSepoliaWalletE(mergedWallets, {
          address: live,
          usdc: 0,
          eth: 0,
        });
      }
    } else {
      nextWallets = withSepoliaWalletE(mergedWallets, null);
    }
    setSimWallets(nextWallets);
    setTransfers(mergedTransfers);
    setChainEvents(mergedEvents);
    writeSession({
      simWallets: nextWallets,
      transfers: mergedTransfers,
      chainEvents: mergedEvents,
    });
    return nextWallets;
  }, [caseId, writeSession]);

  /**
   * Wallet E Event trail from Sepolia SwapObserved, not Railway Anvil/demo memory.
   */
  const refreshSepoliaEvents = useCallback(async (wallet?: string | null) => {
    const addr = wallet ?? liveEAddressRef.current;
    if (!addr) return;
    const rows = await listSepoliaSwapObserved(addr as Address);
    const incoming = rows.map(hookEventFromSepolia);
    const merged = mergeHookEvents(sessionRef.current.chainEvents, incoming);
    setChainEvents(merged);
    writeSession({ chainEvents: merged });
  }, [writeSession]);

  /**
   * Pulls live opinion for a wallet. Cached pack wins when Railway reseeds.
   */
  const refreshCompliance = useCallback(
    async (id: DemoCaseId, amountUsd?: number) => {
      try {
        const { policy } = await fetchPolicy();
        setPolicyKnobs(policy);
        setDemoTick((n) => n + 1);
      } catch {
        /* keep last knobs */
      }
      const pack = await fetchCompliance(id, amountUsd ?? swapAmountUsd);
      const chosen = preferFresherCompliance(
        sessionRef.current.complianceByWallet[id],
        pack,
      );
      setComplianceByWallet((prev) => ({ ...prev, [id]: chosen }));
      setCompliance(chosen);
      writeSession({
        complianceByWallet: {
          ...sessionRef.current.complianceByWallet,
          [id]: chosen,
        },
      });
      return chosen;
    },
    [swapAmountUsd, writeSession],
  );

  /** Bootstrap API after the session snapshot is in memory. */
  useEffect(() => {
    if (!sessionReady) return;
    let cancelled = false;
    (async () => {
      try {
        const health = await fetchHealth();
        if (cancelled) return;
        if (health.policy) setPolicyKnobs(health.policy);
        if (!health.ok || health.chain?.ok === false) {
          setApiStatus("offline");
          setApiError(null);
          return;
        }
        await refreshLedger();
        if (cancelled) return;
        setApiStatus("online");
        setApiError(null);
        try {
          await refreshCompliance(sessionRef.current.caseId);
        } catch {
          /* Opinion / live COA may 500; A–D swaps still settle */
        }
      } catch {
        if (cancelled) return;
        setApiStatus("offline");
        setApiError(null);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshCompliance, refreshLedger, sessionReady]);

  /** Keep compliance in sync when the selected wallet changes (API online). */
  useEffect(() => {
    const cached = complianceByWalletRef.current[caseId];
    if (cached) setCompliance(cached);
    if (apiStatus !== "online") return;
    let cancelled = false;
    (async () => {
      try {
        const pack = await refreshCompliance(caseId);
        if (cancelled) return;
        setAddress((prev) => prev ?? pack.address);
      } catch (err) {
        if (cancelled) return;
        if (cached) {
          setCompliance(cached);
          return;
        }
        setApiError(
          err instanceof ApiError ? err.message : "Failed to load compliance",
        );
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [apiStatus, caseId, refreshCompliance]);

  const handleConnect = async (id: DemoCaseId) => {
    setConnectError(null);
    if (id === "E") {
      try {
        const eoa = await connectSepoliaAccount();
        liveEAddressRef.current = eoa;
        setLiveEAddress(eoa);
        try {
          await postBindWalletE(eoa);
        } catch {
          /* Railway may not have /demo/wallet-e yet; local overlay still applies */
        }
        let usdc = 0;
        let weth = 0;
        try {
          const bal = await readSepoliaBalances(eoa);
          usdc = bal.usdc;
          weth = bal.weth;
          setNativeEth(bal.nativeEth);
        } catch {
          setNativeEth(null);
        }
        setSimWallets((prev) =>
          withSepoliaWalletE(prev, { address: eoa, usdc, eth: weth }),
        );
        setCaseId("E");
        setSimActiveId("E");
        setSwapAmountUsd(DEMO_CASES.E.activity.amountUsd);
        setAddress(eoa);
        setConnected(true);
        setRunning(false);
        setModalOpen(false);
        const cached = complianceByWalletRef.current.E;
        if (cached) setCompliance(cached);
        goToStage("swap", "E");
        void refreshLedger().catch(() => undefined);
        void refreshCompliance("E").catch(() => undefined);
        return;
      } catch (err) {
        setConnectError(err instanceof Error ? err.message : "MetaMask connect failed");
        return;
      }
    }

    liveEAddressRef.current = null;
    setLiveEAddress(null);
    const wallet = simWallets[id];
    setCaseId(id);
    setSimActiveId(id);
    setSwapAmountUsd(DEMO_CASES[id].activity.amountUsd);
    setAddress(wallet.address);
    setConnected(true);
    setRunning(false);
    setModalOpen(false);
    const cached = complianceByWalletRef.current[id];
    if (cached) setCompliance(cached);
    goToStage("swap", id);
  };

  const handleDisconnect = () => {
    setConnected(false);
    setRunning(false);
    liveEAddressRef.current = null;
    setLiveEAddress(null);
    setSwapError(null);
    setConnectError(null);
  };

  const handleUseInUniswap = (id: SimWalletId) => {
    const mapped = caseIdForSimWallet(id);
    const wallet = simWallets[id];
    setSimActiveId(id);
    setCaseId(mapped);
    setSwapAmountUsd(DEMO_CASES[mapped].activity.amountUsd);
    setAddress(wallet.address);
    setConnected(true);
    setRunning(false);
    setMetaMaskOpen(false);
    const cached = complianceByWalletRef.current[mapped];
    if (cached) setCompliance(cached);
    goToStage("swap", mapped);
    if (mapped === "E") {
      void refreshLedger();
    }
  };

  const handleSendTransfer = async (
    from: SimWalletId,
    to: SimWalletId,
    amountUsd: number,
  ): Promise<string | null> => {
    if (from === "E" || to === "E") {
      return "Wallet E is the live Sepolia MetaMask account. Mint MockUSDC on Sepolia instead.";
    }
    if (apiStatus !== "online") {
      return "Request failed";
    }
    try {
      const res = await postTransfer(from, to, amountUsd);
      const nextWallets = preserveLiveE(
        walletsRecord(res.wallets),
        sessionRef.current.simWallets.E,
      );
      const nextTransfers = mergeTransfers(sessionRef.current.transfers, [
        res.transfer,
      ]);
      setSimWallets(nextWallets);
      setTransfers(nextTransfers);
      let nextPacks = { ...sessionRef.current.complianceByWallet };
      if (res.recipientCompliance) {
        const recipient = preferFresherCompliance(
          nextPacks[res.recipientCompliance.walletId],
          res.recipientCompliance,
        );
        nextPacks = { ...nextPacks, [recipient.walletId]: recipient };
        setComplianceByWallet(nextPacks);
        if (recipient.walletId === caseId) setCompliance(recipient);
      }
      writeSession({
        simWallets: nextWallets,
        transfers: nextTransfers,
        complianceByWallet: nextPacks,
      });
      await refreshCompliance(caseId);
      setApiError(null);
      return null;
    } catch (err) {
      const msg = err instanceof ApiError ? err.message : "Transfer failed";
      setApiError(msg);
      return msg;
    }
  };

  const handleMint = async (
    id: SimWalletId,
    token: "usdc" | "eth",
    amount: number,
  ): Promise<string | null> => {
    if (apiStatus !== "online") {
      return "Request failed";
    }
    if (id === "E") {
      const eoa =
        liveEAddressRef.current ?? liveEAddress ?? simWallets.E.address;
      if (!isBoundWalletE(eoa)) {
        return "Connect MetaMask as Wallet E before minting.";
      }
      try {
        await postDemoFaucet(eoa);
        const bal = await readSepoliaBalances(eoa as Address);
        setNativeEth(bal.nativeEth);
        const nextWallets = withSepoliaWalletE(sessionRef.current.simWallets, {
          address: bal.address,
          usdc: bal.usdc,
          eth: bal.weth,
        });
        setSimWallets(nextWallets);
        writeSession({ simWallets: nextWallets });
        setApiError(null);
        return null;
      } catch (err) {
        const msg = err instanceof ApiError ? err.message : "Mint failed";
        setApiError(msg);
        return msg;
      }
    }
    try {
      const res = await postDemoMint(id, token, amount);
      const nextWallets = preserveLiveE(
        walletsRecord(res.wallets),
        sessionRef.current.simWallets.E,
      );
      setSimWallets(nextWallets);
      writeSession({ simWallets: nextWallets });
      setApiError(null);
      return null;
    } catch (err) {
      const msg = err instanceof ApiError ? err.message : "Mint failed";
      setApiError(msg);
      return msg;
    }
  };

  /**
   * Reseeds A–E to the use-case baseline and returns the demo to Swap.
   */
  const handleRestartData = useCallback(async () => {
    persistPausedRef.current = true;
    clearDemoSession();
    setRunning(false);
    setModalOpen(false);
    setMetaMaskOpen(false);
    liveEAddressRef.current = null;
    setLiveEAddress(null);
    setSwapError(null);
    setConnectError(null);
    setNativeEth(null);
    setSwapStats(EMPTY_STATS);
    setTransfers([]);
    setChainEvents([]);
    setCompliance(null);
    setComplianceByWallet({});
    setSimWallets(initialSimWallets());
    setSwapAmountUsd(DEMO_CASES[caseId].activity.amountUsd);
    visitedRef.current = new Set<DemoStage>(["swap"]);
    pointStage("swap");
    setUnlockByWallet(EMPTY_UNLOCK);
    setAuditRevealKey((k) => k + 1);
    setDemoTick((n) => n + 1);
    sessionRef.current = {
      v: 1,
      simWallets: initialSimWallets(),
      transfers: [],
      chainEvents: [],
      swapStats: EMPTY_STATS,
      complianceByWallet: {},
      unlockByWallet: EMPTY_UNLOCK,
      caseId,
      connected,
      swapAmountUsd: DEMO_CASES[caseId].activity.amountUsd,
      stage: "swap",
    };
    window.scrollTo({ top: 0, behavior: "smooth" });

    if (apiStatus === "online") {
      try {
        const res = await postReset();
        const health = await fetchHealth();
        if (health.policy) setPolicyKnobs(health.policy);
        const nextWallets = withSepoliaWalletE(
          walletsRecord(res.wallets),
          null,
        );
        const nextEvents = res.events
          ? res.events.map((ev, i) => hookEventFromApi(ev, i + 1))
          : (await fetchEvents(caseId, undefined, "demo")).events.map((ev, i) =>
              hookEventFromApi(ev, i + 1),
            );
        setSimWallets(nextWallets);
        setTransfers(res.transfers);
        setChainEvents(nextEvents);
        sessionRef.current = {
          ...sessionRef.current,
          simWallets: nextWallets,
          transfers: res.transfers,
          chainEvents: nextEvents,
        };
        persistPausedRef.current = false;
        const pack = await refreshCompliance(caseId);
        setAddress((prev) => (connected ? pack.address : prev));
        setPriceFeedBound(true);
        setApiError(null);
        writeSession({
          simWallets: nextWallets,
          transfers: res.transfers,
          chainEvents: nextEvents,
          swapStats: EMPTY_STATS,
          unlockByWallet: EMPTY_UNLOCK,
          complianceByWallet: { [pack.walletId]: pack },
          stage: "swap",
          swapAmountUsd: DEMO_CASES[caseId].activity.amountUsd,
        });
        return;
      } catch (err) {
        persistPausedRef.current = false;
        setApiError(
          err instanceof ApiError ? err.message : "Failed to restart data",
        );
        writeSession({
          simWallets: initialSimWallets(),
          transfers: [],
          chainEvents: [],
          swapStats: EMPTY_STATS,
          complianceByWallet: {},
          unlockByWallet: EMPTY_UNLOCK,
          stage: "swap",
          swapAmountUsd: DEMO_CASES[caseId].activity.amountUsd,
        });
        return;
      }
    }

    persistPausedRef.current = false;
    setApiError(null);
    writeSession({
      simWallets: initialSimWallets(),
      transfers: [],
      chainEvents: [],
      swapStats: EMPTY_STATS,
      complianceByWallet: {},
      unlockByWallet: EMPTY_UNLOCK,
      stage: "swap",
      swapAmountUsd: DEMO_CASES[caseId].activity.amountUsd,
    });
    setDemoTick((n) => n + 1);
  }, [apiStatus, caseId, connected, pointStage, refreshCompliance, writeSession]);

  /**
   * Event → Swap: jump to the first screen without reseeding.
   * Ledger (USDC/ETH after the last swap or P2P) stays until Restart data.
   */
  const handleBackToSwap = useCallback(async () => {
    setRunning(false);
    goToStage("swap");
    window.scrollTo({ top: 0, behavior: "smooth" });

    if (apiStatus !== "online") return;

    try {
      const wallets = await refreshLedger();
      const remaining = Math.max(0, Math.floor(wallets[caseId].usdc));
      const nextAmount = remaining <= 0 ? 0 : Math.min(swapAmountUsd, remaining);
      setSwapAmountUsd(nextAmount);
      await refreshCompliance(caseId, nextAmount);
      setApiError(null);
    } catch (err) {
      setApiError(
        err instanceof ApiError ? err.message : "Failed to refresh balances",
      );
    }
  }, [
    apiStatus,
    caseId,
    goToStage,
    refreshCompliance,
    refreshLedger,
    swapAmountUsd,
  ]);

  const handleAdvanceClock = useCallback(async () => {
    if (apiStatus === "online") {
      try {
        await postDemoElapse(301);
        await refreshCompliance(caseId);
        setApiError(null);
      } catch (err) {
        setApiError(
          err instanceof ApiError ? err.message : "Failed to advance clock",
        );
      }
    }
    setDemoTick((n) => n + 1);
  }, [apiStatus, caseId, refreshCompliance]);

  useEffect(() => {
    if (stage !== "event") return;
    if (caseId === "E") {
      void refreshSepoliaEvents().catch(() => {
        /* keep local trail */
      });
      const tick = window.setInterval(() => {
        void refreshSepoliaEvents().catch(() => {
          /* keep local trail */
        });
      }, 8_000);
      return () => window.clearInterval(tick);
    }
    if (apiStatus !== "online") return;
    void refreshLedger().catch(() => {
      /* keep local trail */
    });
  }, [apiStatus, caseId, refreshLedger, refreshSepoliaEvents, stage]);

  useEffect(() => {
    if (caseId !== "E" || !liveEAddress) return;
    void refreshSepoliaEvents(liveEAddress).catch(() => undefined);
  }, [caseId, liveEAddress, refreshSepoliaEvents]);

  const settleDemoSwap = useCallback(async () => {
    if (caseId === "E" || apiStatus !== "online") return;
    const amount = demoCase.activity.amountUsd;
    const res = await postSwap(caseId, amount);
    const ev = res.event ?? {
      id: `ev-local-${Date.now()}`,
      walletId: caseId,
      address: res.wallet.address,
      score: res.quote.score,
      decision: res.quote.hookOutput,
      feeBps: res.quote.feeBps,
      amountUsd: res.quote.usdcIn,
      hopDistance: res.wallet.hopDistance ?? null,
      origin: res.wallet.originId ?? "n/a",
      at: new Date().toISOString(),
      kind: res.settled ? "SwapObserved" : "WalletBlocked",
    } as const;
    const nextEvents = mergeHookEvents(sessionRef.current.chainEvents, [
      hookEventFromApi(ev, sessionRef.current.chainEvents.length + 1),
    ]);
    setChainEvents(nextEvents);
    const nextWallets = {
      ...sessionRef.current.simWallets,
      [caseId]: {
        ...sessionRef.current.simWallets[caseId],
        ...toSimWallet(res.wallet),
      },
    };
    setSimWallets(nextWallets);
    let nextPacks = { ...sessionRef.current.complianceByWallet };
    const prevPack = nextPacks[caseId];
    const fromQuote: ApiCompliancePack | undefined = prevPack
      ? {
          ...prevPack,
          score: res.quote.score,
          decision: res.quote.decision,
          hookOutput: res.quote.hookOutput,
          appliedFeeBps: res.quote.feeBps,
          feePercent: res.quote.feePercent,
          hopDistance: res.wallet.hopDistance ?? prevPack.hopDistance,
          originId: res.wallet.originId ?? prevPack.originId,
          usdc: res.wallet.usdc,
          eth: res.wallet.eth,
          keeperPending:
            res.wallet.keeperPending ?? prevPack.keeperPending,
          latencyMitigation:
            res.quote.latencyMitigation ?? prevPack.latencyMitigation,
          revertReason: res.quote.revertReason ?? prevPack.revertReason,
        }
      : undefined;
    if (res.compliance) {
      const chosen = preferFresherCompliance(fromQuote ?? prevPack, res.compliance);
      nextPacks = { ...nextPacks, [chosen.walletId]: chosen };
      setComplianceByWallet(nextPacks);
      setCompliance(chosen);
    } else if (fromQuote) {
      nextPacks = { ...nextPacks, [caseId]: fromQuote };
      setComplianceByWallet(nextPacks);
      setCompliance(fromQuote);
    }
    setApiError(null);
    writeSession({
      simWallets: nextWallets,
      chainEvents: nextEvents,
      complianceByWallet: nextPacks,
    });
    void refreshLedger().catch(() => undefined);
    void refreshCompliance(caseId).catch(() => undefined);
  }, [
    apiStatus,
    caseId,
    demoCase.activity.amountUsd,
    refreshCompliance,
    refreshLedger,
    writeSession,
  ]);

  const recordLocalDemoSwap = useCallback(() => {
    const ev = {
      ...buildHookChainEvent({
        demoCase,
        walletId: caseId,
        address: simWallets[caseId].address,
        eventIndex: sessionRef.current.chainEvents.length + 1,
      }),
      source: "demo" as const,
    };
    const nextEvents = mergeHookEvents(sessionRef.current.chainEvents, [ev]);
    setChainEvents(nextEvents);
    const blocked = demoCase.decision === "block";
    const amount = demoCase.activity.amountUsd;
    const ethOut = blocked ? 0 : ethOutFromSwap(amount, demoCase.appliedFeeBps);
    const current = sessionRef.current.swapStats[caseId];
    const nextStats = {
      ...sessionRef.current.swapStats,
      [caseId]: {
        count: current.count + (blocked ? 0 : 1),
        tradedUsd: current.tradedUsd + (blocked ? 0 : amount),
        tradedEth: current.tradedEth + ethOut,
      },
    };
    setSwapStats(nextStats);
    writeSession({ chainEvents: nextEvents, swapStats: nextStats });
  }, [caseId, demoCase, simWallets, writeSession]);

  const handleSimulate = async () => {
    if (!connected || running || swapBusy || caseId === "E") return;
    if (demoCase.decision !== "block" && demoCase.activity.amountUsd <= 0)
      return;
    if (
      demoCase.decision !== "block" &&
      simWallets[caseId].usdc < demoCase.activity.amountUsd
    ) {
      return;
    }
    recordLocalDemoSwap();
    if (apiStatus === "online") {
      setSwapBusy(true);
      try {
        await settleDemoSwap();
      } catch (err) {
        setApiError(
          err instanceof ApiError ? err.message : "Swap settlement failed",
        );
      } finally {
        setSwapBusy(false);
      }
    }
    goToStage("hook");
    setRunning(true);
  };

  const handleLiveSwap = async () => {
    if (!connected || caseId !== "E" || swapBusy) return;
    const eoa = liveEAddressRef.current ?? liveEAddress;
    if (!eoa) {
      setSwapError("Connect Wallet E with MetaMask on Sepolia first.");
      return;
    }
    const amount = demoCase.activity.amountUsd;
    if (amount <= 0) {
      setSwapError("Enter a USDC amount greater than 0.");
      return;
    }
    setSwapBusy(true);
    setSwapError(null);
    try {
      const { receipt } = await swapUsdcForWeth(eoa as Address, amount);
      let rows = swapObservedFromReceipt(receipt, amount);
      if (rows.length === 0) {
        rows = await swapObservedFromTx(receipt.transactionHash, amount);
      }
      const incoming = rows.map(hookEventFromSepolia);
      const nextEvents = mergeHookEvents(
        sessionRef.current.chainEvents,
        incoming,
      );
      setChainEvents(nextEvents);
      writeSession({ chainEvents: nextEvents });
      goToStage("hook");
      setRunning(true);
      if (apiStatus === "online") {
        void postOracleAfterSwap("E")
          .then(() => refreshCompliance("E", amount))
          .catch(() => refreshCompliance("E", amount));
        void refreshLedger().catch(() => undefined);
      }
      void refreshSepoliaEvents(eoa).catch(() => undefined);
    } catch (err) {
      setSwapError(err instanceof Error ? err.message : "Swap failed");
    } finally {
      setSwapBusy(false);
    }
  };

  const handleFaucet = async (raw: string): Promise<string | null> => {
    if (apiStatus !== "online") {
      return "Request failed";
    }
    setFaucetBusy(true);
    try {
      const res = await postDemoFaucet(raw);
      if (res.address) {
        liveEAddressRef.current = res.address;
        setLiveEAddress(res.address);
        setAddress(res.address);
      }
      await refreshLedger();
      setApiError(null);
      return null;
    } catch (err) {
      return err instanceof ApiError ? err.message : "Faucet failed";
    } finally {
      setFaucetBusy(false);
    }
  };

  /**
   * Enters a module and unlocks the next one so the user can click forward.
   */
  const arriveAt = useCallback(
    (arrived: DemoStage) => {
      if (arrived === "stats" || arrived === "opinion") {
        setAuditRevealKey((k) => k + 1);
      }
      pointStage(arrived);
      const nxt = STAGE_ORDER[STAGE_ORDER.indexOf(arrived) + 1];
      bumpUnlock(nxt ?? arrived, caseId);
      window.scrollTo({ top: 0, behavior: "smooth" });
    },
    [bumpUnlock, caseId, pointStage],
  );

  const handleFlowComplete = useCallback(() => {
    setRunning(false);
    bumpUnlock("fees", caseId);
  }, [bumpUnlock, caseId]);

  const handleStageSelect = (next: DemoStage) => {
    if (next === "swap" && !connected) {
      setModalOpen(true);
      return;
    }
    if (next === "stats" && stage === "stats") return;
    if (next === "opinion" && stage === "opinion") return;
    if (next === "event" && stage === "event") return;
    if (next === "hook" && !running && stage !== "hook") {
      pointStage(next);
      return;
    }
    if (next === "fees" || next === "stats" || next === "opinion") {
      arriveAt(next);
      return;
    }
    pointStage(next);
  };

  /**
   * Wheel / click guided step move without opening the Connect modal.
   */
  const moveStageBy = useCallback(
    (dir: 1 | -1) => {
      const cur = stageRef.current;
      const unlocked = unlockedRef.current;
      const idx = STAGE_ORDER.indexOf(cur);
      const nextIdx = idx + dir;
      if (nextIdx < 0 || nextIdx >= STAGE_ORDER.length) return false;

      const next = STAGE_ORDER[nextIdx];
      if (
        dir > 0 &&
        STAGE_ORDER.indexOf(next) > STAGE_ORDER.indexOf(unlocked)
      ) {
        return false;
      }

      if (dir > 0) {
        arriveAt(next);
        return true;
      }

      pointStage(next);
      window.scrollTo({ top: 0, behavior: "smooth" });
      return true;
    },
    [arriveAt, pointStage],
  );

  /**
   * Click advances by half-screen (left=prev, right=next). Wheel only scrolls.
   */
  useEffect(() => {
    if (appView !== "hook" || modalOpen || metaMaskOpen) return;

    const SLIDE_MS = 2000;
    const OPINION_SLIDE_MS = SLIDE_MS * 3;
    const SWIFT_MS = 420;
    const MANUAL = new Set<DemoStage>([
      "swap",
      "hook",
      "fees",
      "stats",
      "opinion",
      "event",
    ]);
    const lockNav = (ms: number) => {
      wheelLockRef.current = true;
      window.setTimeout(() => {
        wheelLockRef.current = false;
      }, ms);
    };

    const tryMove = (dir: 1 | -1) => {
      if (wheelLockRef.current) return false;
      const cur = stageRef.current;
      const idx = STAGE_ORDER.indexOf(cur);
      const next = STAGE_ORDER[idx + dir];
      const revisit = Boolean(next && visitedRef.current.has(next));
      if (moveStageBy(dir)) {
        const hold =
          dir < 0 || revisit
            ? SWIFT_MS + 80
            : next === "opinion"
              ? OPINION_SLIDE_MS + 150
              : SLIDE_MS + 150;
        lockNav(hold);
        return true;
      }
      return false;
    };

    const isInteractive = (el: EventTarget | null) => {
      if (!(el instanceof Element)) return false;
      return Boolean(
        el.closest(
          "a, button, input, textarea, select, label, [role='button'], nav, [data-no-stage-nav]",
        ),
      );
    };

    const onClick = (e: MouseEvent) => {
      const cur = stageRef.current;
      if (!MANUAL.has(cur)) return;
      if (isInteractive(e.target)) return;

      const goPrev = e.clientX < window.innerWidth / 2;

      if (cur === "event" && !goPrev) return;

      tryMove(goPrev ? -1 : 1);
    };

    window.addEventListener("click", onClick);
    return () => {
      window.removeEventListener("click", onClick);
    };
  }, [appView, modalOpen, metaMaskOpen, moveStageBy]);

  return (
    <main className="relative min-h-dvh overflow-x-hidden">
      {appView === "hook" && (
        <StageSideNav
          stage={stage}
          unlockedThrough={unlockedThrough}
          disabled={modalOpen || metaMaskOpen}
          onPrev={() => {
            void moveStageBy(-1);
          }}
          onNext={() => {
            void moveStageBy(1);
          }}
        />
      )}
      <div className="relative z-10 mx-auto w-full px-5 sm:px-8 md:px-12 lg:px-16">
        <NavBar
          view={appView}
          onViewChange={(next) => {
            setAppView(next);
            window.scrollTo(0, 0);
          }}
          connected={connected}
          address={address}
          walletId={connected ? caseId : null}
          riskBorderClass={
            connected ? walletTone(simWallets[caseId]).border : undefined
          }
          onConnectClick={() => setModalOpen(true)}
          onDisconnect={handleDisconnect}
          onMetaMaskClick={() => setMetaMaskOpen(true)}
        />

        {appView === "whitepaper" && <WhitepaperView />}
        {appView === "use-of-case" && <UseOfCaseView />}
        {appView !== "hook" ? null : (

        <section className="relative pb-6 pt-6 md:pt-8">
          <StageMorph
            stageKey={`title-${stage}`}
            direction={slideDir}
            slow={!slideSwift && stage === "opinion"}
            swift={slideSwift}
          >
          {stage === "swap" && (
            <div className="mb-6 text-center md:mb-8">
              <h1 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
                Swap
              </h1>
            </div>
          )}

          {stage === "hook" && (
            <div className="mb-6 text-center md:mb-8">
              <h2 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
                Hook execution
              </h2>
            </div>
          )}

          {stage === "fees" && (
            <div className="mb-6 text-center md:mb-8">
              <h2 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
                Fee summary
              </h2>
            </div>
          )}

          {stage === "stats" && (
            <div className="mb-6 text-center md:mb-8">
              <h2 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
                AML stats
              </h2>
            </div>
          )}

          {stage === "opinion" && (
            <div className="mb-6 text-center md:mb-8">
              <h2 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
                AML Analysis
              </h2>
            </div>
          )}

          {stage === "event" && (
            <div className="mb-6 text-center md:mb-8">
              <h2 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
                Event
              </h2>
            </div>
          )}
          </StageMorph>

          <div className="relative z-20 mx-auto mb-8 w-full max-w-[560px] border-b hair pb-4 md:mb-10">
            <StageRail
              stage={stage}
              unlockedThrough={unlockedThrough}
              onSelect={handleStageSelect}
            />
          </div>

          <StageMorph
            stageKey={stage}
            direction={slideDir}
            slow={!slideSwift && stage === "opinion"}
            swift={slideSwift}
          >
              {stage === "swap" && (
                  <div data-stage-module className="mx-auto w-full max-w-[560px] pb-8">
                    <SwapWidget
                      demoCase={demoCase}
                      connected={connected}
                      walletUsdc={simWallets[caseId].usdc}
                      walletEth={simWallets[caseId].eth}
                      onConnectClick={() => setModalOpen(true)}
                      onSimulate={handleSimulate}
                      onLiveSwap={caseId === "E" ? () => void handleLiveSwap() : undefined}
                      onFaucet={caseId === "E" ? handleFaucet : undefined}
                      faucetBusy={faucetBusy}
                      swapBusy={swapBusy}
                      swapError={swapError}
                      nativeEth={nativeEth}
                      liveAddress={liveEAddress}
                      onAmountChange={setSwapAmountUsd}
                      onAdvanceClock={
                        caseId === "E"
                          ? undefined
                          : () => {
                              void handleAdvanceClock();
                            }
                      }
                    />
                  </div>
              )}

              {stage === "hook" && (
                  <div data-stage-module className="mx-auto w-full max-w-[1040px] px-2 pb-4 sm:px-3">
                    <FlowSimulator
                      demoCase={demoCase}
                      running={running}
                      onComplete={() => {
                        void handleFlowComplete();
                      }}
                    />
                  </div>
              )}

              {stage === "fees" && (
                  <div data-stage-module className="relative mx-auto w-full max-w-[1100px] px-2 pb-24 sm:px-4">
                    <FeeSummary
                      demoCase={demoCase}
                      swapCount={liveStats.count}
                      tradedUsd={liveStats.tradedUsd}
                      tradedEth={liveStats.tradedEth}
                    />
                  </div>
              )}

              {stage === "stats" && (
                  <div data-stage-module className="relative px-2 pb-2 sm:px-3">
                    <AmlStats
                      demoCase={demoCase}
                      connectedAddress={address}
                      swapCount={liveStats.count}
                      tradedUsd={liveStats.tradedUsd}
                      tradedEth={liveStats.tradedEth}
                    />
                  </div>
              )}

              {stage === "opinion" && (
                  <div data-stage-module className="relative px-2 pb-24 sm:px-3">
                    <LegalOpinion demoCase={demoCase} />
                  </div>
              )}

              {stage === "event" && (
                  <div data-stage-module className="relative mx-auto w-full max-w-[1000px] px-2 pb-24 sm:px-3">
                    <OnChainAccumulator
                      events={trailEvents}
                      showTitle={false}
                      trail={caseId === "E" ? "chain" : "demo"}
                    />
                    <div className="mt-8 flex justify-center">
                      <button
                        type="button"
                        data-no-stage-nav
                        onClick={() => {
                          void handleBackToSwap();
                        }}
                        className="radius-action edge inline-flex items-center gap-2 bg-transparent px-5 py-3 text-sm font-medium text-uni-pink transition hover:bg-uni-pink/5"
                      >
                        <span aria-hidden>←</span>
                        Back to Swap
                      </button>
                    </div>
                  </div>
              )}
          </StageMorph>
        </section>
        )}
      </div>

      {appView === "hook" && showContinueFab && nextModule && (
        <StageContinueFab
          label={nextModule}
          onContinue={() => {
            void moveStageBy(1);
          }}
        />
      )}

      {appView === "hook" && (
      <button
        type="button"
        onClick={() => {
          void handleRestartData();
        }}
        data-no-stage-nav
        title="Restart data"
        aria-label="Restart data"
        className="radius-f surface fixed bottom-5 right-5 z-30 inline-flex items-center gap-2 border-l hair px-3 py-2 text-sm font-medium text-uni-pink transition hover:border-uni-pink/30"
      >
        <span aria-hidden>
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M21 12a9 9 0 1 1-2.6-6.3" />
            <polyline points="21 3 21 9 15 9" />
          </svg>
        </span>
        <span className="hidden sm:inline">Restart data</span>
      </button>
      )}

      <ConnectModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        onConnect={handleConnect}
        wallets={simWallets}
        connectError={connectError}
      />

      <MetaMaskPanel
        open={metaMaskOpen}
        onClose={() => setMetaMaskOpen(false)}
        wallets={simWallets}
        activeId={simActiveId}
        onActiveChange={setSimActiveId}
        onSendTransfer={handleSendTransfer}
        onMint={handleMint}
        nativeEth={nativeEth}
        onUseInUniswap={handleUseInUniswap}
      />
    </main>
  );
}
