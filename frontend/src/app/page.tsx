"use client";

import { useCallback, useState } from "react";
import { AuditReport } from "@/components/AuditReport";
import { CaseSwitcher } from "@/components/CaseSwitcher";
import { ConnectModal } from "@/components/ConnectModal";
import { FeeSummary } from "@/components/FeeSummary";
import { FlowSimulator } from "@/components/FlowSimulator";
import { NavBar } from "@/components/NavBar";
import { SwapWidget } from "@/components/SwapWidget";
import { DEMO_CASES, type DemoCaseId } from "@/data/cases";
import { withVolumeEscalation } from "@/lib/riskEscalation";

/**
 * Root demo page for the AML Hook Uniswap v4 hackathon UI.
 *
 * Flow:
 * 1. User opens the connect modal and picks one of three hardcoded wallets.
 * 2. Case switcher, flow simulator, fee metrics, and audit report appear.
 * 3. "Get started" animates the beforeSwap → decision → result pipeline.
 * 4. After USD 3,000 traded in the 24h window, that wallet’s risk band
 *    upgrades one step (Low→Medium→High).
 */
type SwapStats = { count: number; tradedUsd: number };

const EMPTY_STATS: Record<DemoCaseId, SwapStats> = {
  clean: { count: 0, tradedUsd: 0 },
  structuring: { count: 0, tradedUsd: 0 },
  ofac: { count: 0, tradedUsd: 0 },
};

export default function HomePage() {
  const [caseId, setCaseId] = useState<DemoCaseId>("clean");
  const [modalOpen, setModalOpen] = useState(false);
  const [connected, setConnected] = useState(false);
  const [address, setAddress] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  /** Per-wallet live counters updated when the n8n circuit finishes */
  const [swapStats, setSwapStats] = useState<Record<DemoCaseId, SwapStats>>(EMPTY_STATS);

  const liveStats = swapStats[caseId];
  /** Base case + live 24h volume escalation (USD 3,000 threshold). */
  const demoCase = withVolumeEscalation(
    DEMO_CASES[caseId],
    liveStats.tradedUsd,
    liveStats.count,
  );

  /**
   * Connects a demo wallet: stores its address, selects the matching case,
   * and reveals the simulator / audit sections.
   */
  const handleConnect = (id: DemoCaseId) => {
    const selected = DEMO_CASES[id];
    setCaseId(id);
    setAddress(selected.wallet);
    setConnected(true);
    setRunning(false);
    setModalOpen(false);
  };

  /**
   * Starts the flow animation and scrolls the simulator into view.
   * No-op until a wallet is connected or while an animation is already running.
   */
  const handleSimulate = () => {
    if (!connected || running) return;
    setRunning(true);
    const el = document.getElementById("flow");
    el?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  /**
   * Called by FlowSimulator when the step animation finishes.
   * Bumps the swap counter by 1 and adds this swap's USD amount to the total.
   */
  const handleFlowComplete = useCallback(() => {
    setRunning(false);
    setSwapStats((prev) => {
      const current = prev[caseId];
      const amount = DEMO_CASES[caseId].structuring.amountUsd;
      return {
        ...prev,
        [caseId]: {
          count: current.count + 1,
          tradedUsd: current.tradedUsd + amount,
        },
      };
    });
  }, [caseId]);

  /**
   * Switches the active case from the left-hand circles and updates the
   * connected address to the wallet that belongs to that case.
   */
  const handleCaseChange = (id: DemoCaseId) => {
    if (!connected) return;
    setCaseId(id);
    setAddress(DEMO_CASES[id].wallet);
    setRunning(false);
  };

  return (
    <main className="relative min-h-screen overflow-x-hidden">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-[720px]">
        <div className="bokeh">
          <span className="orb-1" />
          <span className="orb-2" />
          <span className="orb-3" />
          <span className="orb-4" />
        </div>
      </div>

      <NavBar
        connected={connected}
        address={address}
        onConnectClick={() => setModalOpen(true)}
      />

      <section className="relative z-10 pb-10 pt-8 md:pt-14">
        <div className="mx-auto mb-8 max-w-3xl px-4 text-center">
          <h1 className="text-balance text-4xl font-extrabold tracking-tight md:text-5xl">
            AML Hook
          </h1>
          <p className="mt-3 text-sm text-uni-muted md:text-base">
            Uniswap Hook Incubator 10
          </p>
        </div>

        <div className="relative">
          {connected && (
            <div className="absolute left-3 top-0 z-20 md:left-5">
              <CaseSwitcher active={caseId} onChange={handleCaseChange} />
            </div>
          )}
          <div className="mx-auto w-full max-w-[480px] px-4">
            <SwapWidget
              demoCase={demoCase}
              connected={connected}
              onConnectClick={() => setModalOpen(true)}
              onSimulate={handleSimulate}
            />
          </div>
        </div>
      </section>

      {connected && (
        <>
          <div id="flow" className="relative z-10 py-16">
            <div className="mb-12 px-4 pb-6 pt-10 text-center md:mb-16 md:pb-10 md:pt-14">
              <p className="text-sm font-semibold uppercase tracking-[0.22em] text-uni-pink">
                Case
              </p>
              <h2 className="mt-4 text-balance text-4xl font-extrabold tracking-tight md:text-5xl">
                Simulator
              </h2>
            </div>
            <div className="mx-auto w-full max-w-[1400px] px-4">
              <FlowSimulator
                demoCase={demoCase}
                running={running}
                onComplete={handleFlowComplete}
              />
              <FeeSummary
                demoCase={demoCase}
                swapCount={liveStats.count}
                tradedUsd={liveStats.tradedUsd}
              />
            </div>
          </div>

          <div id="audit" className="relative z-10 pt-4">
            <AuditReport demoCase={demoCase} connectedAddress={address} />
          </div>
        </>
      )}

      <ConnectModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        onConnect={handleConnect}
      />
    </main>
  );
}
