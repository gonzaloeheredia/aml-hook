"use client";

import { walletTone } from "@/components/WalletTag";
import { CASE_ORDER, DEMO_CASES, type DemoCaseId } from "@/data/cases";
import type { SimWallet } from "@/lib/hopScoring";

type Props = {
  open: boolean;
  onClose: () => void;
  /** Called when the user picks Wallet A–E */
  onConnect: (caseId: DemoCaseId) => void;
  /** Live ledger — B/C/D stay green until contaminated; E stays unknown */
  wallets: Record<DemoCaseId, SimWallet>;
};

/**
 * Shortens an address for the account picker list.
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Connect modal — wallets A–E.
 * Row border: green clean / score 0 · yellow hop, latency, or unknown · red exploit.
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
      <div className="relative w-full max-w-md animate-fadeUp rounded-3xl border border-uni-border bg-uni-surface p-5 shadow-glow">
        <div className="mb-5 flex items-center justify-between">
          <h2 className="text-xl font-semibold">Choose wallet</h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-full px-3 py-1 text-uni-muted hover:bg-uni-card hover:text-white"
          >
            ✕
          </button>
        </div>

        <p className="mb-3 text-sm text-uni-muted">
          Pick the use-case account to run through the AML Hook:
        </p>
        <div className="space-y-2">
          {CASE_ORDER.map((id) => {
            const c = DEMO_CASES[id];
            const wallet = wallets[id];
            const tone = walletTone(wallet);
            return (
              <button
                key={id}
                type="button"
                onClick={() => onConnect(id)}
                className={`flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left transition hover:brightness-110 ${tone.border} ${tone.bg} ${tone.text}`}
              >
                <span
                  className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-sm font-bold ${tone.badge}`}
                >
                  {id}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-semibold text-white">
                    Wallet {id} · {tone.label}
                  </span>
                  <span className="block truncate font-mono text-xs opacity-80">
                    {shorten(wallet.address)}
                  </span>
                  <span className="mt-0.5 block text-[11px] opacity-80">
                    {wallet.neverScored
                      ? "Unknown · $500 → 3% · $1,000 → 8% · $25,000 → revert"
                      : wallet.keeperPending
                        ? "Keeper pending · inflow 8% on next swap"
                        : wallet.hopDistance != null
                          ? `${wallet.hopDistance}-hop · fee override expected`
                          : id === "D"
                            ? "Score 0 · fund via clean C (no hop) for inflow"
                            : id === "C"
                              ? "Clean · send to D for inflow, or receive from A for 1-hop"
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
