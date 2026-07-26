"use client";

import { useState } from "react";
import { CASE_ORDER, DEMO_CASES, type DemoCaseId } from "@/data/cases";

type Props = {
  open: boolean;
  onClose: () => void;
  /** Called when the user picks one of the demo accounts */
  onConnect: (caseId: DemoCaseId) => void;
};

/**
 * Shortens an address for the account picker list.
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Border / text tone per risk case in the account list */
const TONE: Record<DemoCaseId, string> = {
  clean: "text-uni-ok border-uni-ok/40 bg-uni-ok/10",
  clean2: "text-uni-ok border-uni-ok/40 bg-uni-ok/10",
  structuring: "text-uni-warn border-uni-warn/40 bg-uni-warn/10",
  ofac: "text-uni-bad border-uni-bad/40 bg-uni-bad/10",
};

/**
 * Hardcoded Uniswap-style wallet connect modal.
 * Step 1: pick MetaMask (fake). Step 2: pick one of three demo addresses,
 * each mapped to a risk case (clean ×2 / structuring / OFAC).
 */
export function ConnectModal({ open, onClose, onConnect }: Props) {
  const [step, setStep] = useState<"wallet" | "accounts">("wallet");

  if (!open) return null;

  /**
   * Closes the modal and resets to the wallet-provider step.
   */
  const handleClose = () => {
    setStep("wallet");
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      <button
        type="button"
        aria-label="Close"
        className="absolute inset-0 bg-black/70 backdrop-blur-sm"
        onClick={handleClose}
      />
      <div className="relative w-full max-w-md animate-fadeUp rounded-3xl border border-uni-border bg-uni-surface p-5 shadow-glow">
        <div className="mb-5 flex items-center justify-between">
          <h2 className="text-xl font-semibold">
            {step === "wallet" ? "Connect a wallet" : "Choose address"}
          </h2>
          <button
            type="button"
            onClick={handleClose}
            className="rounded-full px-3 py-1 text-uni-muted hover:bg-uni-card hover:text-white"
          >
            ✕
          </button>
        </div>

        {step === "wallet" ? (
          <>
            <div className="overflow-hidden rounded-2xl border border-uni-border bg-uni-card">
              <button
                type="button"
                className="flex w-full items-center justify-between px-4 py-4 text-left text-uni-muted hover:bg-uni-cardHover"
              >
                <span className="flex items-center gap-3">
                  <span className="flex h-9 w-9 items-center justify-center rounded-full bg-[#FC72FF]/20 text-lg">
                    🦄
                  </span>
                  <span className="font-medium text-white/70">Uniswap Wallet (mobile)</span>
                </span>
                <span>▦</span>
              </button>
              <div className="h-px bg-uni-border" />
              <button
                type="button"
                className="flex w-full items-center justify-between px-4 py-4 text-left hover:bg-uni-cardHover"
                onClick={() => setStep("accounts")}
              >
                <span className="flex items-center gap-3">
                  <span className="flex h-9 w-9 items-center justify-center rounded-full bg-[#E2761B]/20 text-lg">
                    🦊
                  </span>
                  <span className="font-medium">MetaMask</span>
                </span>
                <span className="rounded-full bg-uni-pink/15 px-2.5 py-1 text-xs font-semibold text-uni-pink">
                  Recent
                </span>
              </button>
              <div className="h-px bg-uni-border" />
              <button
                type="button"
                className="flex w-full items-center justify-between px-4 py-4 text-left text-uni-muted hover:bg-uni-cardHover hover:text-white"
              >
                <span className="flex items-center gap-3">
                  <span className="flex h-9 w-9 items-center justify-center rounded-full bg-white/5">
                    ▣
                  </span>
                  <span className="font-medium">Other wallets</span>
                </span>
                <span>›</span>
              </button>
            </div>

            <p className="mt-5 text-center text-xs leading-relaxed text-uni-muted">
              Hardcoded hackathon demo. MetaMask opens four fake addresses — two clean, one risky, one OFAC.
            </p>
          </>
        ) : (
          <>
            <p className="mb-3 text-sm text-uni-muted">
              Select one of the four demo accounts:
            </p>
            <div className="space-y-2">
              {CASE_ORDER.map((id, index) => {
                const c = DEMO_CASES[id];
                return (
                  <button
                    key={id}
                    type="button"
                    onClick={() => {
                      onConnect(id);
                      setStep("wallet");
                    }}
                    className={`flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left transition hover:brightness-110 ${TONE[id]}`}
                  >
                    <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-current/30 bg-black/20 text-sm font-bold">
                      {index + 1}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm font-semibold text-white">
                        {c.walletLabel}
                      </span>
                      <span className="block truncate font-mono text-xs opacity-80">
                        {shorten(c.wallet)}
                      </span>
                      <span className="mt-0.5 block text-[11px] opacity-80">
                        {c.shortLabel} · {c.label}
                      </span>
                    </span>
                  </button>
                );
              })}
            </div>
            <button
              type="button"
              className="mt-4 w-full text-center text-sm text-uni-muted hover:text-white"
              onClick={() => setStep("wallet")}
            >
              ← Back
            </button>
          </>
        )}
      </div>
    </div>
  );
}
