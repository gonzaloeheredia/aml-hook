"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AmlStats, LegalOpinion } from "@/components/AuditReport";
import { ConnectModal } from "@/components/ConnectModal";
import { EscrowPanel } from "@/components/EscrowPanel";
import { FeeSummary } from "@/components/FeeSummary";
import { FlowSimulator } from "@/components/FlowSimulator";
import { MetaMaskPanel } from "@/components/MetaMaskPanel";
import { NavBar, type AppView } from "@/components/NavBar";
import { UseOfCaseView } from "@/components/UseOfCaseView";
import { WhitepaperView } from "@/components/WhitepaperView";
import { OnChainAccumulator } from "@/components/OnChainAccumulator";
import { StageMorph } from "@/components/StageMorph";
import { StageRail, type DemoStage } from "@/components/StageRail";
import { StageSideNav } from "@/components/StageSideNav";
import { SwapWidget } from "@/components/SwapWidget";
import { walletTone } from "@/components/WalletTag";
import { DEMO_CASES, type DemoCaseId } from "@/data/cases";
import {
  API_BASE,
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
  postDemoMint,
  walletsRecord,
  type ApiCompliancePack,
} from "@/lib/api";
import {
  caseIdForSimWallet,
  ethOutFromSwap,
  initialSimWallets,
  setPolicyKnobs,
  setPriceFeedBound,
  type SimWallet,
  type SimWalletId,
  type TransferRecord,
} from "@/lib/hopScoring";
import {
  hookEventFromApi,
  type HookChainEvent,
} from "@/lib/hookEvents";
import { applyLiveCaseCopy } from "@/lib/liveCaseCopy";
import { withComplianceOverlay } from "@/lib/withComplianceOverlay";

/**
 * Demo page — guided stages with horizontal slides:
 * Swap → Hook (auto), then Fees → AML stats → Opinion → Event (click / wheel).
 * Event has a Back to Swap control; ledger balances persist until Restart data.
 */
type SwapStats = { count: number; tradedUsd: number; tradedEth: number };

const EMPTY_STATS: Record<DemoCaseId, SwapStats> = {
  A: { count: 0, tradedUsd: 0, tradedEth: 0 },
  B: { count: 0, tradedUsd: 0, tradedEth: 0 },
  C: { count: 0, tradedUsd: 0, tradedEth: 0 },
  D: { count: 0, tradedUsd: 0, tradedEth: 0 },
  E: { count: 0, tradedUsd: 0, tradedEth: 0 },
};

type ApiStatus = "connecting" | "online" | "offline";

const STAGE_ORDER: DemoStage[] = [
  "swap",
  "hook",
  "fees",
  "stats",
  "opinion",
  "event",
];

/** After landing on Fees, wait out the forward slide plus this hold, then Stats. */
const FEES_TO_STATS_MS = 3000;
const OPINION_TO_EVENT_MS = 15_000;

/**
 * Returns the later of two stages in the guided sequence.
 */
function maxStage(a: DemoStage, b: DemoStage): DemoStage {
  return STAGE_ORDER.indexOf(a) >= STAGE_ORDER.indexOf(b) ? a : b;
}

export default function HomePage() {
  const [caseId, setCaseId] = useState<DemoCaseId>("A");
  const [modalOpen, setModalOpen] = useState(false);
  const [metaMaskOpen, setMetaMaskOpen] = useState(false);
  const [connected, setConnected] = useState(false);
  const [address, setAddress] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [swapStats, setSwapStats] = useState<Record<DemoCaseId, SwapStats>>(
    EMPTY_STATS,
  );

  const [simWallets, setSimWallets] = useState<Record<SimWalletId, SimWallet>>(
    () => initialSimWallets(),
  );
  const [simActiveId, setSimActiveId] = useState<SimWalletId>("A");
  const [, setTransfers] = useState<TransferRecord[]>([]);
  const [chainEvents, setChainEvents] = useState<HookChainEvent[]>([]);
  const [, setAuditRevealKey] = useState(0);

  const [stage, setStage] = useState<DemoStage>("swap");
  const [slideDir, setSlideDir] = useState<1 | -1>(1);
  const [slideSwift, setSlideSwift] = useState(false);
  const [unlockedThrough, setUnlockedThrough] =
    useState<DemoStage>("swap");

  const [appView, setAppView] = useState<AppView>("hook");
  const [apiStatus, setApiStatus] = useState<ApiStatus>("connecting");
  const [apiError, setApiError] = useState<string | null>(null);
  const [compliance, setCompliance] = useState<ApiCompliancePack | null>(null);
  const [swapAmountUsd, setSwapAmountUsd] = useState(
    DEMO_CASES.A.activity.amountUsd,
  );
  const [demoTick, setDemoTick] = useState(0);

  const wheelLockRef = useRef(false);
  const feesHoldRef = useRef(false);
  const stageRef = useRef(stage);
  const unlockedRef = useRef(unlockedThrough);
  const visitedRef = useRef<Set<DemoStage>>(new Set<DemoStage>(["swap"]));
  stageRef.current = stage;
  unlockedRef.current = unlockedThrough;

  const liveStats = swapStats[caseId];
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
  const goToStage = useCallback((next: DemoStage) => {
    pointStage(next);
    setUnlockedThrough((prev) => maxStage(prev, next));
  }, [pointStage]);

  /**
   * Loads wallets, transfers, and events from the backend.
   * Returns the live A–E map so callers can cap the next swap to remaining USDC.
   */
  const refreshLedger = useCallback(async () => {
    const [walletsRes, transfersRes, eventsRes] = await Promise.all([
      fetchWallets(),
      fetchTransfers(),
      fetchEvents(),
    ]);
    const wallets = walletsRecord(walletsRes.wallets);
    setSimWallets(wallets);
    setTransfers(transfersRes.transfers);
    setChainEvents(
      eventsRes.events.map((ev, i) => hookEventFromApi(ev, i + 1)),
    );
    return wallets;
  }, []);

  /**
   * Pulls live opinion for the active wallet from the API.
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
      setCompliance(pack);
      return pack;
    },
    [swapAmountUsd],
  );

  /** Bootstrap API connection on mount. */
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const health = await fetchHealth();
        if (cancelled) return;
        if (health.policy) setPolicyKnobs(health.policy);
        if (!health.ok || health.chain?.ok === false) {
          throw new ApiError(
            health.chain?.reason ||
              "Anvil stack is down. Run npm run deploy:local and restart the API.",
            503,
          );
        }
        await refreshLedger();
        if (cancelled) return;
        await refreshCompliance("A");
        if (cancelled) return;
        setApiStatus("online");
        setApiError(null);
      } catch (err) {
        if (cancelled) return;
        setApiStatus("offline");
        setApiError(
          err instanceof ApiError
            ? err.message
            : `Cannot reach API at ${API_BASE}`,
        );
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshCompliance, refreshLedger]);

  /** Keep compliance in sync when the selected wallet changes (API online). */
  useEffect(() => {
    if (apiStatus !== "online") return;
    let cancelled = false;
    (async () => {
      try {
        const pack = await refreshCompliance(caseId);
        if (cancelled) return;
        setAddress((prev) => prev ?? pack.address);
      } catch (err) {
        if (cancelled) return;
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
    goToStage("swap");
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
    goToStage("swap");
  };

  const handleSendTransfer = async (
    from: SimWalletId,
    to: SimWalletId,
    amountUsd: number,
  ): Promise<string | null> => {
    if (apiStatus !== "online") {
      return "Anvil is required. Run npm run deploy:local and start the API.";
    }
    try {
      const res = await postTransfer(from, to, amountUsd);
      setSimWallets(walletsRecord(res.wallets));
      setTransfers((prev) => [...prev, res.transfer]);
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
      return "Anvil is required. Run npm run deploy:local and start the API.";
    }
    try {
      const res = await postDemoMint(id, token, amount);
      setSimWallets(walletsRecord(res.wallets));
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
    setRunning(false);
    setModalOpen(false);
    setMetaMaskOpen(false);
    setSwapStats(EMPTY_STATS);
    setTransfers([]);
    setChainEvents([]);
    visitedRef.current = new Set<DemoStage>(["swap"]);
    pointStage("swap");
    setUnlockedThrough("swap");
    setAuditRevealKey((k) => k + 1);
    setDemoTick((n) => n + 1);
    window.scrollTo({ top: 0, behavior: "smooth" });

    if (apiStatus === "online") {
      try {
        const res = await postReset();
        const health = await fetchHealth();
        if (health.policy) setPolicyKnobs(health.policy);
        setSimWallets(walletsRecord(res.wallets));
        setTransfers(res.transfers);
        setChainEvents(
          res.events.map((ev, i) => hookEventFromApi(ev, i + 1)),
        );
        const pack = await refreshCompliance(caseId);
        setAddress((prev) => (connected ? pack.address : prev));
        setPriceFeedBound(true);
        setApiError(null);
        return;
      } catch (err) {
        setApiError(
          err instanceof ApiError ? err.message : "Failed to restart data",
        );
      }
    }

    setApiError("Anvil is required. Run npm run deploy:local and start the API.");
    setCompliance(null);
    setDemoTick((n) => n + 1);
  }, [apiStatus, caseId, connected, pointStage, refreshCompliance]);

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
    } else {
      setApiError("Anvil is required. Run npm run deploy:local and start the API.");
    }
    setDemoTick((n) => n + 1);
  }, [apiStatus, caseId, refreshCompliance]);

  const handleSimulate = () => {
    if (!connected || running) return;
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

  /**
   * Opens AML stats and unlocks the Opinion module.
   */
  const enterStats = useCallback(() => {
    setAuditRevealKey((k) => k + 1);
    pointStage("stats");
    setUnlockedThrough((prev) => maxStage(prev, "opinion"));
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, [pointStage]);

  /**
   * Lands on Fees after the hook run. Holds 3s after the forward slide,
   * then advances to Stats.
   */
  const landOnFees = useCallback(() => {
    pointStage("fees");
    setUnlockedThrough((prev) => maxStage(prev, "fees"));
    feesHoldRef.current = true;
    wheelLockRef.current = true;
    const settleMs = 2000;
    window.setTimeout(() => {
      feesHoldRef.current = false;
      wheelLockRef.current = false;
      if (stageRef.current !== "fees") return;
      enterStats();
    }, settleMs + FEES_TO_STATS_MS);
  }, [pointStage, enterStats]);

  /**
   * Opens Opinion. Event stays locked until the 15s scroll window elapses.
   */
  const enterOpinion = useCallback(() => {
    setAuditRevealKey((k) => k + 1);
    pointStage("opinion");
    setUnlockedThrough((prev) => maxStage(prev, "opinion"));
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, [pointStage]);

  /**
   * First visit to Opinion: wait for the slide, then 15s to scroll the file,
   * then unlock Event and advance. Revisit (Event already seen): just unlock.
   */
  useEffect(() => {
    if (stage !== "opinion") return;

    if (visitedRef.current.has("event")) {
      setUnlockedThrough((prev) => maxStage(prev, "event"));
      return;
    }

    const settleMs = slideSwift ? 420 : 6000;
    const t = window.setTimeout(() => {
      if (stageRef.current !== "opinion") return;
      setUnlockedThrough((prev) => maxStage(prev, "event"));
      pointStage("event");
      window.scrollTo({ top: 0, behavior: "smooth" });
    }, settleMs + OPINION_TO_EVENT_MS);

    return () => window.clearTimeout(t);
  }, [stage, slideSwift, pointStage]);

  const handleFlowComplete = useCallback(async () => {
    setRunning(false);
    const amount = demoCase.activity.amountUsd;

    if (apiStatus !== "online") {
      setApiError("Anvil is required. Run npm run deploy:local and start the API.");
      landOnFees();
      return;
    }

    if (apiStatus === "online") {
      try {
        await postSwap(caseId, amount);
        await refreshLedger();
        const pack = await refreshCompliance(caseId);
        const ethOut =
          pack.decision === "block"
            ? 0
            : ethOutFromSwap(amount, pack.appliedFeeBps);
        setSwapStats((prev) => {
          const current = prev[caseId];
          return {
            ...prev,
            [caseId]: {
              count: current.count + 1,
              tradedUsd: current.tradedUsd + (ethOut > 0 ? amount : 0),
              tradedEth: current.tradedEth + ethOut,
            },
          };
        });
        setApiError(null);
        landOnFees();
        return;
      } catch (err) {
        setApiError(
          err instanceof ApiError ? err.message : "Swap settlement failed",
        );
        landOnFees();
      }
    }
  }, [
    address,
    apiStatus,
    caseId,
    demoCase,
    landOnFees,
    refreshCompliance,
    refreshLedger,
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
    if (next === "stats") {
      enterStats();
      return;
    }
    if (next === "opinion") {
      enterOpinion();
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

      if (next === "stats" && cur !== "stats") {
        setAuditRevealKey((k) => k + 1);
        pointStage("stats");
        setUnlockedThrough((prev) => maxStage(prev, "opinion"));
        window.scrollTo({ top: 0, behavior: "smooth" });
        return true;
      }

      if (next === "opinion" && cur !== "opinion") {
        setAuditRevealKey((k) => k + 1);
        pointStage("opinion");
        setUnlockedThrough((prev) => maxStage(prev, "opinion"));
        window.scrollTo({ top: 0, behavior: "smooth" });
        return true;
      }

      pointStage(next);
      if (dir > 0) {
        setUnlockedThrough((prev) => maxStage(prev, next));
      }
      window.scrollTo({ top: 0, behavior: "smooth" });
      return true;
    },
    [pointStage],
  );

  /**
   * All stages: click advances by half-screen (left=prev, right=next).
   * Wheel still scrolls vertically first; stage change only at scroll edges.
   * Opinion → Event: click only, right half, after scrolling to the end of the module.
   */
  useEffect(() => {
    if (appView !== "hook" || modalOpen || metaMaskOpen) return;

    const TOP_EPS = 40;
    const DELTA_THRESHOLD = 48;
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
    let acc = 0;

    const lockNav = (ms: number) => {
      wheelLockRef.current = true;
      window.setTimeout(() => {
        wheelLockRef.current = false;
      }, ms);
    };

    const scrollEdges = () => {
      const maxScroll = Math.max(
        0,
        document.documentElement.scrollHeight - window.innerHeight,
      );
      const scrollY = window.scrollY;
      return {
        atTop: scrollY <= TOP_EPS,
        atBottom: scrollY >= maxScroll - TOP_EPS,
      };
    };

    const tryMove = (dir: 1 | -1) => {
      if (wheelLockRef.current || feesHoldRef.current) return false;
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

      // Opinion → Event: only right-half click at the end of the module
      if (cur === "opinion" && !goPrev) {
        const { atBottom } = scrollEdges();
        if (!atBottom) return;
      }

      tryMove(goPrev ? -1 : 1);
    };

    const onWheel = (e: WheelEvent) => {
      if (wheelLockRef.current) {
        e.preventDefault();
        return;
      }

      const cur = stageRef.current;
      if (!MANUAL.has(cur)) return;

      const { atTop, atBottom } = scrollEdges();
      const goingDown = e.deltaY > 0;
      const goingUp = e.deltaY < 0;

      if ((goingDown && !atBottom) || (goingUp && !atTop)) {
        acc = 0;
        return;
      }

      // Opinion never advances to Event via wheel — scroll-read, then click
      if (cur === "opinion" && goingDown) {
        e.preventDefault();
        acc = 0;
        return;
      }

      e.preventDefault();
      acc += e.deltaY;
      if (Math.abs(acc) < DELTA_THRESHOLD) return;
      const dir: 1 | -1 = acc > 0 ? 1 : -1;
      acc = 0;
      tryMove(dir);
    };

    window.addEventListener("click", onClick);
    window.addEventListener("wheel", onWheel, { passive: false });
    return () => {
      window.removeEventListener("click", onClick);
      window.removeEventListener("wheel", onWheel);
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

        {appView === "hook" && apiStatus === "offline" && (
          <div className="mx-auto mb-2 w-full max-w-[560px] border-l-[1.5px] border-uni-bad/50 px-4 py-2 text-sm text-uni-bad">
            {apiError ??
              `Run \`npm run deploy:local\`, then start apps/api (${API_BASE}).`}
          </div>
        )}

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
                    <EscrowPanel
                      apiOnline={apiStatus === "online"}
                      tick={demoTick + liveStats.count}
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
                      events={chainEvents}
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
