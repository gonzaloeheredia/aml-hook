"use client";

import { useCallback, useState } from "react";
import { AuditReport } from "@/components/AuditReport";
import { CaseSwitcher } from "@/components/CaseSwitcher";
import { ConnectModal } from "@/components/ConnectModal";
import { FeeSummary } from "@/components/FeeSummary";
import { FlowSimulator } from "@/components/FlowSimulator";
import { MetaMaskPanel } from "@/components/MetaMaskPanel";
import { NavBar } from "@/components/NavBar";
import { SwapWidget } from "@/components/SwapWidget";
import { DEMO_CASES, type DemoCaseId } from "@/data/cases";
import {
  applyPoolSwap,
  caseIdForSimWallet,
  initialSimWallets,
  type SimWalletId,
  type TransferRecord,
} from "@/lib/hopScoring";
import { buildHookChainEvent, type HookChainEvent } from "@/lib/hookEvents";
import { withHopOverlay } from "@/lib/withHopOverlay";

/**
 * Demo page — A/B clean until C transfers; then N-hop fee overrides.
 */
type SwapStats = { count: number; tradedUsd: number };

const EMPTY_STATS: Record<DemoCaseId, SwapStats> = {
  A: { count: 0, tradedUsd: 0 },
  B: { count: 0, tradedUsd: 0 },
  C: { count: 0, tradedUsd: 0 },
};

export default function HomePage() {
  const [caseId, setCaseId] = useState<DemoCaseId>("A");
  const [modalOpen, setModalOpen] = useState(false);
  const [metaMaskOpen, setMetaMaskOpen] = useState(false);
  const [connected, setConnected] = useState(false);
  const [address, setAddress] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [swapStats, setSwapStats] = useState<Record<DemoCaseId, SwapStats>>(EMPTY_STATS);

  const [simWallets, setSimWallets] = useState(() => initialSimWallets());
  const [simActiveId, setSimActiveId] = useState<SimWalletId>("A");
  const [transfers, setTransfers] = useState<TransferRecord[]>([]);
  /** Audit trail of afterSwap SwapObserved / beforeSwap WalletBlocked emits */
  const [chainEvents, setChainEvents] = useState<HookChainEvent[]>([]);
  /** AML analysis only reveals after the node simulator finishes */
  const [auditReady, setAuditReady] = useState(false);
  const [auditRevealKey, setAuditRevealKey] = useState(0);

  const liveStats = swapStats[caseId];
  const baseCase = DEMO_CASES[caseId];
  /** Always reflect live MetaMask hop state for the selected wallet. */
  const demoCase = withHopOverlay(baseCase, simWallets[caseId]);

  const handleConnect = (id: DemoCaseId) => {
    const wallet = simWallets[id];
    setCaseId(id);
    setSimActiveId(id);
    setAddress(wallet.address);
    setConnected(true);
    setRunning(false);
    setAuditReady(false);
    setModalOpen(false);
  };

  const handleUseInUniswap = (id: SimWalletId) => {
    const mapped = caseIdForSimWallet(id);
    const wallet = simWallets[id];
    setSimActiveId(id);
    setCaseId(mapped);
    setAddress(wallet.address);
    setConnected(true);
    setRunning(false);
    setAuditReady(false);
    setMetaMaskOpen(false);
  };

  const handleSimulate = () => {
    if (!connected || running) return;
    if (demoCase.decision !== "block" && demoCase.activity.amountUsd <= 0) return;
    if (demoCase.decision !== "block" && simWallets[caseId].usdc < demoCase.activity.amountUsd) {
      return;
    }
    setAuditReady(false);
    setRunning(true);
    document.getElementById("flow")?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const handleFlowComplete = useCallback(() => {
    setRunning(false);
    const liveCase = withHopOverlay(DEMO_CASES[caseId], simWallets[caseId]);
    const amount = liveCase.activity.amountUsd;
    const walletAddress = address ?? liveCase.wallet;

    // Settle USDC→ETH against MetaMask ledger when the hook allows the swap
    if (liveCase.decision !== "block") {
      const nextWallets = applyPoolSwap(
        simWallets,
        caseId,
        amount,
        liveCase.appliedFeeBps,
        liveCase.decision,
      );
      if (nextWallets) {
        setSimWallets(nextWallets);
      }
    }

    setSwapStats((prev) => {
      const current = prev[caseId];
      return {
        ...prev,
        [caseId]: {
          count: current.count + 1,
          tradedUsd: current.tradedUsd + (liveCase.decision === "block" ? 0 : amount),
        },
      };
    });

    setChainEvents((events) => [
      ...events,
      buildHookChainEvent({
        demoCase: liveCase,
        walletId: caseId,
        address: walletAddress,
        eventIndex: events.length + 1,
      }),
    ]);

    setAuditRevealKey((k) => k + 1);
    setAuditReady(true);
    // Bring the AML title into view; remaining blocks reveal as the user scrolls
    window.setTimeout(() => {
      document.getElementById("audit")?.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 220);
  }, [address, caseId, simWallets]);

  const handleCaseChange = (id: DemoCaseId) => {
    if (!connected) return;
    setCaseId(id);
    setSimActiveId(id);
    setAddress(simWallets[id].address);
    setRunning(false);
    setAuditReady(false);
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

      <div className="relative z-10 mx-auto w-full px-5 sm:px-8 md:px-12 lg:px-16">
        <NavBar
          connected={connected}
          address={address}
          onConnectClick={() => setModalOpen(true)}
          onMetaMaskClick={() => setMetaMaskOpen(true)}
        />

        <section className="relative pb-10 pt-8 md:pt-14">
          <div className="mx-auto mb-8 max-w-3xl text-center">
            <h1 className="text-balance text-4xl font-extrabold tracking-tight md:text-5xl">
              AML Hook
            </h1>
            <p className="mt-3 text-sm text-uni-muted md:text-base">
              A/B clean until C transfers · then N-hop decay
            </p>
          </div>

          <div className="relative">
            {connected && (
              <div className="absolute left-0 top-0 z-20">
                <CaseSwitcher active={caseId} onChange={handleCaseChange} />
              </div>
            )}
            <div className="mx-auto w-full max-w-[480px]">
              <SwapWidget
                demoCase={demoCase}
                connected={connected}
                walletUsdc={simWallets[caseId].usdc}
                walletEth={simWallets[caseId].eth}
                onConnectClick={() => setModalOpen(true)}
                onSimulate={handleSimulate}
              />
            </div>
          </div>
        </section>

        {connected && (
          <>
            <div id="flow" className="relative px-4 py-16 sm:px-8 md:px-14 lg:px-24">
              <div className="mb-12 pb-6 pt-10 text-center md:mb-16 md:pb-10 md:pt-14">
                <p className="text-sm font-semibold uppercase tracking-[0.22em] text-uni-pink">
                  Case
                </p>
                <h2 className="mt-4 text-balance text-4xl font-extrabold tracking-tight md:text-5xl">
                  Simulator
                </h2>
              </div>
              <div className="mx-auto w-full max-w-[1200px]">
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

            {auditReady && (
              <div
                id="audit"
                key={auditRevealKey}
                className="relative px-4 pt-4 sm:px-8 md:px-14 lg:px-24"
              >
                <AuditReport
                  demoCase={demoCase}
                  connectedAddress={address}
                  chainEvents={chainEvents}
                />
              </div>
            )}
          </>
        )}
      </div>

      <ConnectModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        onConnect={handleConnect}
      />

      <MetaMaskPanel
        open={metaMaskOpen}
        onClose={() => setMetaMaskOpen(false)}
        wallets={simWallets}
        transfers={transfers}
        activeId={simActiveId}
        onActiveChange={setSimActiveId}
        onWalletsChange={setSimWallets}
        onTransfer={(record) => setTransfers((prev) => [...prev, record])}
        onUseInUniswap={handleUseInUniswap}
      />
    </main>
  );
}
