"use client";

import { walletTone } from "@/components/WalletTag";
import { CASE_ORDER, DEMO_CASES, type DemoCaseId } from "@/data/cases";
import {
  formatFeePct,
  formatUsdFloor,
  getPolicyKnobs,
  midBandExampleUsd,
  type SimWallet,
} from "@/lib/hopScoring";

type Props = {
  open: boolean;
  onClose: () => void;
  /** Called when the user picks Wallet A–F */
  onConnect: (caseId: DemoCaseId) => void;
  /** Live ledger — B/C/D stay green until contaminated; E stays unknown; F is OFAC SDN */
  wallets: Record<DemoCaseId, SimWallet>;
};

/**
 * Shortens an address for the account picker list.
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Connect modal — wallets A–F.
 * Row border: green clean / score 0 · yellow hop, latency, or unknown · red exploit or OFAC SDN.
 */
export function ConnectModal({ open, onClose, onConnect, wallets }: Props) {
  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      <button
        type="button"
        aria-label="Close"
        className="absolute inset-0 bg-black/70 backdrop-blur-sm"
        onClick={onClose}
      />
      <div className="surface radius-b relative w-full max-w-md animate-fadeUp border-l hair p-6">
        <div className="mb-5 flex items-center justify-between">
          <h2 className="font-serif text-xl">Choose wallet</h2>
          <button
            type="button"
            onClick={onClose}
            className="px-3 py-1 text-uni-muted hover:bg-uni-pink/5 hover:text-uni-pink"
          >
            ✕
          </button>
        </div>

        <p className="mb-3 text-sm text-uni-muted">
          Pick the use-case account to run through the AML Hook:
        </p>
        <div className="space-y-0">
          {CASE_ORDER.map((id) => {
            const c = DEMO_CASES[id];
            const wallet = wallets[id];
            const tone = walletTone(wallet);
            return (
              <button
                key={id}
                type="button"
                onClick={() => onConnect(id)}
                className={`flex w-full items-center gap-3 border-l px-4 py-3.5 text-left transition hover:bg-uni-pink/[0.03] ${tone.border} ${tone.text}`}
              >
                <span
                  className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-sm font-bold ${tone.badge}`}
                >
                  {id}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-semibold text-uni-pink">
                    Wallet {id} · {tone.label}
                  </span>
                  <span className="block truncate font-mono text-xs opacity-80">
                    {shorten(wallet.address)}
                  </span>
                  <span className="mt-0.5 block text-[11px] opacity-80">
                    {wallet.neverScored
                      ? wallet.usdc <= 0
                        ? "Unknown · empty — fund from clean C (no hop)"
                        : `Unknown · bag $${wallet.usdc.toLocaleString("en-US")} · Floor A/D on next swap`
                      : wallet.keeperPending
                        ? `Keeper pending · next swap uses inflow ${formatFeePct(getPolicyKnobs().proportionalFeeBps)} / ${formatFeePct(getPolicyKnobs().punitiveFeeBps)} by inbound USD`
                        : wallet.hopDistance != null
                          ? `${wallet.hopDistance}-hop · fee override expected`
                          : id === "D"
                            ? `Score 0 · held funds 0.30% · clean C→D ${formatUsdFloor(midBandExampleUsd())}=${formatFeePct(getPolicyKnobs().proportionalFeeBps)} / ${formatUsdFloor(getPolicyKnobs().unscoredRevertThresholdUsd)}=${formatFeePct(getPolicyKnobs().punitiveFeeBps)}`
                            : id === "C"
                              ? "Clean · fund E (unknown) or D (inflow); A→C is 1-hop"
                              : id === "A"
                                ? "Exploit · score 100 · pool WalletBlocked · P2P still contaminates B/C"
                                : c.label}
                  </span>
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
