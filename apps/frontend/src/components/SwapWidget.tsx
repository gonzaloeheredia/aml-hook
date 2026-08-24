"use client";

import type { DemoCase } from "@/data/cases";
import {
  bandLabelForUsd,
  formatFeePct,
  formatUsdFloor,
  getPolicyKnobs,
} from "@/lib/hopScoring";

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
  priceFeedBound?: boolean;
  onAdvanceClock?: () => void;
  onTogglePriceFeed?: () => void;
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
  onAmountChange,
  priceFeedBound = true,
  onAdvanceClock,
  onTogglePriceFeed,
}: Props) {
  const blocked = demoCase.decision === "block";
  const insufficient = connected && !blocked && walletUsdc < demoCase.activity.amountUsd;

  return (
    <div className="mx-auto w-full max-w-[480px] animate-fadeUp">
      <div className="rounded-[24px] border border-uni-border bg-uni-surface/90 p-2 shadow-glow backdrop-blur">
        <div className="mb-1 px-3 pt-2">
          <span className="text-base font-semibold">Swap</span>
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
          {connected && demoCase.amountPresets && onAmountChange && (
            <div className="mt-3 space-y-2">
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
                      className={`rounded-full px-3 py-1 text-xs font-semibold transition ${
                        active
                          ? "bg-uni-pink text-black"
                          : "bg-uni-surface text-uni-muted hover:text-white"
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

        {connected && onAdvanceClock && onTogglePriceFeed && (
          <div className="mt-2 flex flex-wrap gap-2 px-1">
            <button
              type="button"
              onClick={onAdvanceClock}
              className="rounded-full bg-uni-surface px-3 py-1 text-xs font-semibold text-uni-muted transition hover:text-white"
            >
              Advance 5 min
            </button>
            <button
              type="button"
              onClick={onTogglePriceFeed}
              className="rounded-full bg-uni-surface px-3 py-1 text-xs font-semibold text-uni-muted transition hover:text-white"
            >
              {priceFeedBound ? "Unbind price feed" : "Bind price feed"}
            </button>
          </div>
        )}

        {connected && blocked && (
          <div className="mt-2 rounded-2xl border border-uni-bad/30 bg-uni-bad/10 px-4 py-3 text-sm text-uni-bad">
            {demoCase.revertReason === "SanctionHit"
              ? "This wallet is on the demo OFAC list. beforeSwap reverts with SanctionHit — the score is not read."
              : demoCase.revertReason === "WalletBlocked" && demoCase.exploitConfirmed
                ? "Wallet A is not on OFAC. The officer wrote score 100 (confirmed exploit). beforeSwap reverts with WalletBlocked (SCORE_REVERT_BAND)."
              : demoCase.latencyMitigation === "MAGNITUDE_QUOTE_FAILED"
                ? "No usable USD price. The swap fail-closes (MagnitudeQuoteFailed)."
                : demoCase.latencyMitigation === "DAILY_AGGREGATION" ||
                    demoCase.latencyMitigation === "ACTIVITY_WINDOW_CAP"
                  ? `24-hour USD crossed ${formatUsdFloor(getPolicyKnobs().unscoredRevertThresholdUsd)} (Floor C). The swap reverts.`
                  : demoCase.id === "E" ||
                      demoCase.latencyMitigation === "SCORE_NEVER_WRITTEN"
                    ? `Unknown wallet: this swap is ${formatUsdFloor(getPolicyKnobs().unscoredRevertThresholdUsd)} or more, or Floor C just fired. The swap reverts.`
                    : "Exploit cash-out / confirmed exposure. The swap reverts before settlement."}
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
