"use client";

import type { DemoCase } from "@/data/cases";
import { bandLabelForUsd, formatFeePct } from "@/lib/hopScoring";

type Props = {
  demoCase: DemoCase;
  connected: boolean;
  /** Live MetaMask USDC balance for the connected account */
  walletUsdc: number;
  /** Live MetaMask ETH balance for the connected account */
  walletEth: number;
  onConnectClick: () => void;
  onSimulate: () => void;
  /** Size chips for Wallet E (and any case with amountPresets). */
  onAmountChange?: (amountUsd: number) => void;
  onAdvanceClock?: () => void;
};

/**
 * Swap card: USDC→ETH amounts stay in sync with MetaMask balances.
 */
export function SwapWidget({
  demoCase,
  connected,
  walletUsdc,
  walletEth,
  onConnectClick,
  onSimulate,
  onAmountChange,
  onAdvanceClock,
}: Props) {
  const blocked = demoCase.decision === "block";
  const insufficient = connected && !blocked && walletUsdc < demoCase.activity.amountUsd;

  return (
    <div className="w-full">
      <div className="surface radius-a border-l border-t hair p-4 md:p-5">
        <div className="border-b hair pb-4">
          <div className="mb-2 flex items-baseline justify-between">
            <span className="label-kicker">Sell</span>
            {connected && (
              <span className="text-[11px] tracking-wide text-uni-muted">
                Balance {walletUsdc.toLocaleString("en-US")} USDC
              </span>
            )}
          </div>
          <div className="flex items-end justify-between gap-3">
            <div className="value-hero text-uni-pink">
              {connected ? demoCase.swapSell : "0"}
            </div>
            <button
              type="button"
              className="mb-1 flex items-center gap-2 border-b hair px-1 pb-1 text-sm font-medium"
            >
              <span className="flex h-6 w-6 items-center justify-center rounded-full bg-[#2775CA] text-[10px]">
                $
              </span>
              {demoCase.sellToken}
              <span className="text-uni-muted">▾</span>
            </button>
          </div>
          <div className="mt-2 text-[12px] tracking-wide text-uni-muted">
            ${connected ? demoCase.activity.amountUsd.toLocaleString("en-US") : "0"}
            <span className="ml-2">{demoCase.sellToken}</span>
          </div>
          {connected && demoCase.amountPresets && onAmountChange && (
            <div className="mt-4 space-y-2">
              <div className="flex flex-wrap gap-2">
                {demoCase.amountPresets.map((preset) => {
                  const active = demoCase.activity.amountUsd === preset;
                  const live =
                    active &&
                    (demoCase.decision === "block"
                      ? "revert"
                      : formatFeePct(demoCase.appliedFeeBps));
                  const predicted = bandLabelForUsd(preset, walletUsdc);
                  return (
                    <button
                      key={preset}
                      type="button"
                      onClick={() => onAmountChange(preset)}
                      className={`px-2 py-1 text-xs font-medium transition ${
                        active
                          ? "radius-chip bg-uni-pink text-black"
                          : "text-uni-muted hover:text-uni-pink"
                      }`}
                    >
                      ${preset.toLocaleString("en-US")}
                      {` · ${live ?? predicted}`}
                    </button>
                  );
                })}
              </div>
              {demoCase.id === "E" && (
                <p className="text-[11px] leading-snug text-uni-muted">
                  {walletUsdc <= 0
                    ? "E starts empty. In MetaMask, send USDC from clean C (no hop). Do not fund E from A."
                    : "Quote from the hook. Floor A is this swap; Floor D is the bag C sent. The stricter fee wins."}
                </p>
              )}
            </div>
          )}
        </div>

        <div className="py-2 pl-0.5 text-sm text-uni-muted">↓</div>

        <div className="pb-1">
          <div className="mb-2 flex items-baseline justify-between">
            <span className="label-kicker">Buy</span>
            {connected && (
              <span className="text-[11px] tracking-wide text-uni-muted">
                Balance {walletEth.toLocaleString("en-US", { maximumFractionDigits: 4 })} ETH
              </span>
            )}
          </div>
          <div className="flex items-end justify-between gap-3">
            <div className="value-hero text-uni-pink/90">
              {connected ? demoCase.swapBuy : "0"}
            </div>
            <button
              type="button"
              className="mb-1 flex items-center gap-2 border-b hair px-1 pb-1 text-sm font-medium"
            >
              {demoCase.buyToken}
              <span>▾</span>
            </button>
          </div>
        </div>

        {connected && onAdvanceClock && (
          <div className="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={onAdvanceClock}
              className="border-b hair px-0.5 pb-0.5 text-xs font-medium text-uni-muted transition hover:text-uni-pink"
            >
              Advance 5 min
            </button>
          </div>
        )}

        {insufficient && (
          <div className="mt-4 border-l-[1.5px] border-uni-warn/50 bg-transparent py-2 pl-3 text-sm text-uni-warn">
            Insufficient USDC in MetaMask for this swap.
          </div>
        )}

        <button
          type="button"
          onClick={connected ? onSimulate : onConnectClick}
          disabled={connected && (insufficient || (blocked === false && demoCase.activity.amountUsd <= 0))}
          className="radius-action edge mt-4 w-full bg-transparent py-3.5 text-center text-lg font-medium text-uni-pink transition hover:bg-uni-pink/5 disabled:cursor-not-allowed disabled:opacity-40"
        >
          Get started
        </button>
      </div>
    </div>
  );
}
