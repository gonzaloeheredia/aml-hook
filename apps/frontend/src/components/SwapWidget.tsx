"use client";

import { useEffect, useState } from "react";
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
  /** Wallet E: exact-in swap on the live Sepolia pool via Universal Router. */
  onLiveSwap?: () => void;
  /** Wallet E: mint 1,000 MockUSDC + 1 MockWETH to the connected Sepolia EOA. */
  onFaucet?: (address: string) => Promise<string | null>;
  faucetBusy?: boolean;
  swapBusy?: boolean;
  swapError?: string | null;
  nativeEth?: number | null;
  liveAddress?: string | null;
  /** Sell size in USDC. */
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
  onLiveSwap,
  onFaucet,
  faucetBusy = false,
  swapBusy = false,
  swapError = null,
  nativeEth,
  liveAddress,
  onAmountChange,
  onAdvanceClock,
}: Props) {
  const livePool = demoCase.id === "E" && Boolean(onLiveSwap);
  const blocked = demoCase.decision === "block";
  const insufficient =
    connected &&
    !livePool &&
    !blocked &&
    walletUsdc < demoCase.activity.amountUsd;
  const [faucetAddress, setFaucetAddress] = useState(liveAddress ?? "");
  const [faucetError, setFaucetError] = useState<string | null>(null);
  const ePresets =
    demoCase.id === "E" && demoCase.amountPresets?.length
      ? demoCase.amountPresets
      : [];
  const [draft, setDraft] = useState(String(demoCase.activity.amountUsd));
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    if (!editing) setDraft(String(demoCase.activity.amountUsd));
  }, [demoCase.activity.amountUsd, editing]);

  useEffect(() => {
    if (liveAddress) setFaucetAddress(liveAddress);
  }, [liveAddress]);

  const commitAmount = () => {
    if (!onAmountChange) return;
    setEditing(false);
    const n = Math.max(0, Math.floor(Number(draft.replace(/[^\d]/g, "")) || 0));
    const next = blocked ? n : Math.min(n, Math.max(0, Math.floor(walletUsdc)));
    setDraft(String(next));
    onAmountChange(next);
  };

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
            {connected && onAmountChange ? (
              <input
                type="text"
                inputMode="numeric"
                data-no-stage-nav
                aria-label="Sell amount in USDC"
                value={editing ? draft : demoCase.swapSell}
                onFocus={() => {
                  setEditing(true);
                  setDraft(String(demoCase.activity.amountUsd));
                }}
                onChange={(e) => {
                  setEditing(true);
                  setDraft(e.target.value.replace(/[^\d]/g, ""));
                }}
                onBlur={commitAmount}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.currentTarget.blur();
                  }
                }}
                className="value-hero min-w-0 flex-1 bg-transparent text-uni-pink outline-none"
              />
            ) : (
              <div className="value-hero text-uni-pink">
                {connected ? demoCase.swapSell : "0"}
              </div>
            )}
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
          {connected && onAmountChange && ePresets.length > 0 && (
            <div className="mt-4 flex flex-wrap gap-2">
              {ePresets.map((preset) => {
                const active = demoCase.activity.amountUsd === preset;
                return (
                  <button
                    key={preset}
                    type="button"
                    data-no-stage-nav
                    onClick={() => onAmountChange(preset)}
                    className={`px-2 py-1 text-xs font-medium transition ${
                      active
                        ? "radius-chip bg-uni-pink text-black"
                        : "text-uni-muted hover:text-uni-pink"
                    }`}
                  >
                    ${preset.toLocaleString("en-US")}
                  </button>
                );
              })}
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

        {livePool && connected && onFaucet && (
          <div className="mt-4">
            <label className="label-kicker" htmlFor="e-faucet-address">
              Sepolia faucet
            </label>
            <div className="mt-2 flex gap-2">
              <input
                id="e-faucet-address"
                type="text"
                spellCheck={false}
                autoComplete="off"
                data-no-stage-nav
                placeholder="0x… Sepolia wallet"
                value={faucetAddress}
                onChange={(e) => {
                  setFaucetAddress(e.target.value.trim());
                  setFaucetError(null);
                }}
                className="min-w-0 flex-1 border-b hair bg-transparent py-1.5 font-mono text-[12px] text-uni-pink outline-none"
              />
              <button
                type="button"
                data-no-stage-nav
                disabled={faucetBusy || faucetAddress.length < 42}
                onClick={() => {
                  void onFaucet(faucetAddress).then((err) => {
                    setFaucetError(err);
                  });
                }}
                className="shrink-0 border-b hair px-0.5 pb-0.5 text-xs font-medium text-uni-muted transition hover:text-uni-pink disabled:cursor-not-allowed disabled:opacity-40"
              >
                {faucetBusy ? "Minting…" : "Mint 1,000 USDC"}
              </button>
            </div>
            {faucetError && (
              <p className="mt-2 text-xs text-uni-warn">{faucetError}</p>
            )}
            {connected && nativeEth === 0 && (
              <p className="mt-2 text-xs text-uni-warn">
                This wallet needs Sepolia ETH for gas. The faucet only mints MockUSDC and MockWETH.
              </p>
            )}
          </div>
        )}

        {insufficient && (
          <div className="mt-4 border-l-[1.5px] border-uni-warn/50 bg-transparent py-2 pl-3 text-sm text-uni-warn">
            Insufficient USDC in MetaMask for this swap.
          </div>
        )}

        <button
          type="button"
          onClick={() => {
            if (!connected) {
              onConnectClick();
              return;
            }
            if (livePool) {
              onLiveSwap?.();
              return;
            }
            onSimulate();
          }}
          disabled={
            connected &&
            (swapBusy ||
              faucetBusy ||
              (livePool
                ? demoCase.activity.amountUsd <= 0
                : insufficient ||
                  (blocked === false && demoCase.activity.amountUsd <= 0)))
          }
          className="radius-action edge mt-4 w-full bg-transparent py-3.5 text-center text-lg font-medium text-uni-pink transition hover:bg-uni-pink/5 disabled:cursor-not-allowed disabled:opacity-40"
        >
          {livePool
            ? swapBusy
              ? "Swapping on Sepolia…"
              : "Swap on Sepolia"
            : "Get started"}
        </button>
        {livePool && swapError && (
          <p className="mt-3 text-sm text-uni-warn">{swapError}</p>
        )}
      </div>
    </div>
  );
}
