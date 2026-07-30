"use client";

import type { DemoCase } from "@/data/cases";

type Props = {
  demoCase: DemoCase;
  connected: boolean;
  /** Live MetaMask USDC balance for the connected account */
  walletUsdc: number;
  /** Live MetaMask ETH balance for the connected account */
  walletEth: number;
  onConnectClick: () => void;
  onSimulate: () => void;
};

/**
 * Uniswap-style swap card — USDC→ETH amounts stay in sync with MetaMask balances.
 */
export function SwapWidget({
  demoCase,
  connected,
  walletUsdc,
  walletEth,
  onConnectClick,
  onSimulate,
}: Props) {
  const blocked = demoCase.decision === "block";
  const warnTone = demoCase.decision === "fee_override";
  const insufficient = connected && !blocked && walletUsdc < demoCase.activity.amountUsd;

  return (
    <div className="mx-auto w-full max-w-[480px] animate-fadeUp">
      <div className="rounded-[24px] border border-uni-border bg-uni-surface/90 p-2 shadow-glow backdrop-blur">
        <div className="mb-1 flex items-center justify-between px-3 pt-2">
          <span className="text-base font-semibold">Swap</span>
          {connected && (
            <span
              className={`rounded-full px-2.5 py-1 text-xs font-semibold ${
                blocked
                  ? "bg-uni-bad/15 text-uni-bad"
                  : warnTone
                    ? "bg-uni-warn/15 text-uni-warn"
                    : "bg-uni-ok/15 text-uni-ok"
              }`}
            >
              {demoCase.riskLabel}
            </span>
          )}
        </div>

        <div className="rounded-[20px] bg-uni-card p-4">
          <div className="mb-2 flex items-center justify-between text-sm text-uni-muted">
            <span>Sell</span>
            {connected && (
              <span className="text-xs">
                Balance {walletUsdc.toLocaleString("en-US")} USDC
              </span>
            )}
          </div>
          <div className="flex items-center justify-between gap-3">
            <div className="text-4xl font-semibold tracking-tight">
              {connected ? demoCase.swapSell : "0"}
            </div>
            <button
              type="button"
              className="flex items-center gap-2 rounded-full bg-uni-surface px-3 py-2 text-sm font-semibold"
            >
              <span className="flex h-6 w-6 items-center justify-center rounded-full bg-[#2775CA] text-[10px]">
                $
              </span>
              {demoCase.sellToken}
              <span className="text-uni-muted">▾</span>
            </button>
          </div>
          <div className="mt-2 flex justify-between text-sm text-uni-muted">
            <span>
              ${connected ? demoCase.activity.amountUsd.toLocaleString("en-US") : "0"}
            </span>
            <span>{demoCase.sellToken}</span>
          </div>
        </div>

        <div className="-my-2 flex justify-center">
          <div className="z-10 flex h-9 w-9 items-center justify-center rounded-xl border-4 border-uni-surface bg-uni-card text-uni-muted">
            ↓
          </div>
        </div>

        <div className="rounded-[20px] bg-uni-card p-4">
          <div className="mb-2 flex items-center justify-between text-sm text-uni-muted">
            <span>Buy</span>
            {connected && (
              <span className="text-xs">
                Balance {walletEth.toLocaleString("en-US", { maximumFractionDigits: 4 })} ETH
              </span>
            )}
          </div>
          <div className="flex items-center justify-between gap-3">
            <div className="text-4xl font-semibold tracking-tight text-white/90">
              {connected ? demoCase.swapBuy : "0"}
            </div>
            <button
              type="button"
              className="flex items-center gap-2 rounded-full bg-uni-pink px-3 py-2 text-sm font-semibold text-black"
            >
              {demoCase.buyToken}
              <span>▾</span>
            </button>
          </div>
        </div>

        {connected && blocked && (
          <div className="mt-2 rounded-2xl border border-uni-bad/30 bg-uni-bad/10 px-4 py-3 text-sm text-uni-bad">
            Exploit cash-out / confirmed exposure. The swap reverts in{" "}
            <span className="font-semibold">beforeSwap</span> (fail-closed).
          </div>
        )}

        {insufficient && (
          <div className="mt-2 rounded-2xl border border-uni-warn/30 bg-uni-warn/10 px-4 py-3 text-sm text-uni-warn">
            Insufficient USDC in MetaMask for this swap.
          </div>
        )}

        <button
          type="button"
          onClick={connected ? onSimulate : onConnectClick}
          disabled={connected && (insufficient || (blocked === false && demoCase.activity.amountUsd <= 0))}
          className="mt-2 w-full rounded-[20px] bg-[#2A1240] py-4 text-center text-lg font-semibold text-uni-pink transition hover:brightness-125 disabled:cursor-not-allowed disabled:opacity-40"
        >
          Get started
        </button>
      </div>
    </div>
  );
}
