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
import { DEMO_CASES, type DemoCaseId } from "@/data/cases";
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
  postDemoFaucet,
  postDemoMint,
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
  setPolicyKnobs,
  setPriceFeedBound,
  type SimWallet,
  type SimWalletId,
} from "@/lib/hopScoring";
import {
  hookEventFromApi,
  mergeHookEvents,
  type HookChainEvent,
} from "@/lib/hookEvents";
import { applyLiveCaseCopy } from "@/lib/liveCaseCopy";
import { UNISWAP_SEPOLIA_POOL_URL } from "@/lib/sepoliaPool";
import { withComplianceOverlay } from "@/lib/withComplianceOverlay";

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

  const liveStats = mergeStats(
    swapStats[caseId],
    statsFromEvents(chainEvents, caseId),
  );

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
        setAddress(snap.simWallets[snap.caseId]?.address ?? null);
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
    return applyLiveCaseCopy(overlaid);
  }, [baseCase, caseId, compliance, demoTick]);

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
    const [walletsRes, transfersRes, eventsRes] = await Promise.all([
      fetchWallets(),
      fetchTransfers(),
      fetchEvents(caseId),
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
    setSimWallets(mergedWallets);
    setTransfers(mergedTransfers);
    setChainEvents(mergedEvents);
    writeSession({
      simWallets: mergedWallets,
      transfers: mergedTransfers,
      chainEvents: mergedEvents,
    });
    return mergedWallets;
  }, [caseId, writeSession]);

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
        await refreshCompliance(sessionRef.current.caseId);
        if (cancelled) return;
        setApiStatus("online");
        setApiError(null);
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

  const handleConnect = (id: DemoCaseId) => {
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
  };

  const handleSendTransfer = async (
    from: SimWalletId,
    to: SimWalletId,
    amountUsd: number,
  ): Promise<string | null> => {
    if (apiStatus !== "online") {
      return "Request failed";
    }
    try {
      const res = await postTransfer(from, to, amountUsd);
      const nextWallets = walletsRecord(res.wallets);
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
    try {
      const res = await postDemoMint(id, token, amount);
      const nextWallets = walletsRecord(res.wallets);
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
        const nextWallets = walletsRecord(res.wallets);
        const nextEvents = res.events
          ? res.events.map((ev, i) => hookEventFromApi(ev, i + 1))
          : (await fetchEvents(caseId)).events.map((ev, i) =>
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
    if (stage !== "event" || apiStatus !== "online") return;
    void refreshLedger().catch(() => {
      /* keep local trail */
    });
    if (caseId !== "E") return;
    const tick = window.setInterval(() => {
      void refreshLedger().catch(() => {
        /* keep local trail */
      });
    }, 12_000);
    return () => window.clearInterval(tick);
  }, [apiStatus, caseId, refreshLedger, stage]);

  const handleSimulate = () => {
    if (!connected || running || caseId === "E") return;
    if (demoCase.decision !== "block" && demoCase.activity.amountUsd <= 0)
      return;
    if (
      demoCase.decision !== "block" &&
      simWallets[caseId].usdc < demoCase.activity.amountUsd
    ) {
      return;
    }
    goToStage("hook");
    setRunning(true);
  };

  const handleOpenPool = () => {
    if (!connected || caseId !== "E") return;
    window.open(UNISWAP_SEPOLIA_POOL_URL, "_blank", "noopener,noreferrer");
    bumpUnlock("event", "E");
    if (apiStatus === "online") {
      void refreshLedger().catch(() => {
        /* Event fills after the Uniswap swap */
      });
    }
  };

  const handleFaucet = async (raw: string): Promise<string | null> => {
    if (apiStatus !== "online") {
      return "Request failed";
    }
    setFaucetBusy(true);
    try {
      await postDemoFaucet(raw);
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

  const handleFlowComplete = useCallback(async () => {
    setRunning(false);
    if (caseId !== "E") {
      bumpUnlock("fees", caseId);
    }
    const amount = demoCase.activity.amountUsd;

    if (caseId === "E" || apiStatus !== "online") {
      return;
    }

    try {
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
      const ethOut =
        !res.settled || res.quote.decision === "block"
          ? 0
          : ethOutFromSwap(amount, res.quote.feeBps);
      const current = sessionRef.current.swapStats[caseId];
      const nextStats = {
        ...sessionRef.current.swapStats,
        [caseId]: {
          count: current.count + 1,
          tradedUsd: current.tradedUsd + (ethOut > 0 ? amount : 0),
          tradedEth: current.tradedEth + ethOut,
        },
      };
      setSwapStats(nextStats);
      let nextPacks = { ...sessionRef.current.complianceByWallet };
      if (res.compliance) {
        const chosen = preferFresherCompliance(
          nextPacks[res.compliance.walletId],
          res.compliance,
        );
        nextPacks = { ...nextPacks, [chosen.walletId]: chosen };
        setComplianceByWallet(nextPacks);
        setCompliance(chosen);
      }
      setApiError(null);
      writeSession({
        chainEvents: nextEvents,
        swapStats: nextStats,
        complianceByWallet: nextPacks,
      });
      await refreshLedger();
      await refreshCompliance(caseId);
    } catch (err) {
      setApiError(
        err instanceof ApiError ? err.message : "Swap settlement failed",
      );
      try {
        await refreshLedger();
      } catch {
        /* keep local trail */
      }
    }
  }, [
    apiStatus,
    bumpUnlock,
    caseId,
    demoCase,
    refreshCompliance,
    refreshLedger,
    writeSession,
  ]);

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
                      onOpenPool={
                        caseId === "E" ? handleOpenPool : undefined
                      }
                      onFaucet={caseId === "E" ? handleFaucet : undefined}
                      faucetBusy={faucetBusy}
                      onAmountChange={setSwapAmountUsd}
                      onAdvanceClock={() => {
                        void handleAdvanceClock();
                      }}
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
                      events={chainEvents.filter((e) => e.walletId === caseId)}
                      showTitle={false}
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
      />

      <MetaMaskPanel
        open={metaMaskOpen}
        onClose={() => setMetaMaskOpen(false)}
        wallets={simWallets}
        activeId={simActiveId}
        onActiveChange={setSimActiveId}
        onSendTransfer={handleSendTransfer}
        onMint={handleMint}
        onUseInUniswap={handleUseInUniswap}
      />
    </main>
  );
}
