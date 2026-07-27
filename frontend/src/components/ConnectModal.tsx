"use client";

import { CASE_ORDER, DEMO_CASES, type DemoCaseId } from "@/data/cases";

type Props = {
  open: boolean;
  onClose: () => void;
  /** Called when the user picks Wallet A / B / C */
  onConnect: (caseId: DemoCaseId) => void;
};

/**
 * Shortens an address for the account picker list.
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Border / text tone per use-case wallet */
const TONE: Record<DemoCaseId, string> = {
  A: "text-uni-ok border-uni-ok/40 bg-uni-ok/10",
  B: "text-uni-ok border-uni-ok/40 bg-uni-ok/10",
  C: "text-uni-bad border-uni-bad/40 bg-uni-bad/10",
};

/**
 * Connect modal — only the three use-case wallets (A / B / C).
 * No unused providers (Uniswap Wallet, Other wallets, etc.).
 */
export function ConnectModal({ open, onClose, onConnect }: Props) {
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
            return (
              <button
                key={id}
                type="button"
                onClick={() => onConnect(id)}
                className={`flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left transition hover:brightness-110 ${TONE[id]}`}
              >
                <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-current/30 bg-black/20 text-sm font-bold">
                  {id}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-semibold text-white">
                    {c.walletLabel}
                  </span>
                  <span className="block truncate font-mono text-xs opacity-80">
                    {shorten(c.wallet)}
                  </span>
                  <span className="mt-0.5 block text-[11px] opacity-80">
                    {c.label}
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
