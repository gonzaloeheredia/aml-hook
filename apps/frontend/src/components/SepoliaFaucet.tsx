"use client";

import { useState } from "react";

type Props = {
  /** Judge faucet: mint MockUSDC + MockWETH to a pasted Sepolia address. */
  onFaucet: (address: string) => Promise<{
    error: string | null;
    usdcTx?: string;
    ethTx?: string;
    address?: string;
  }>;
};

/**
 * Shortens an address or tx hash for the result line.
 */
function shorten(value: string) {
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

/**
 * Judge faucet under the swap card — funds an arbitrary Sepolia address
 * without connecting it or changing A–E.
 */
export function SepoliaFaucet({ onFaucet }: Props) {
  const [address, setAddress] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{
    address: string;
    usdcTx: string;
    ethTx: string;
  } | null>(null);

  const handleMint = async () => {
    const next = address.trim();
    if (!/^0x[a-fA-F0-9]{40}$/.test(next)) {
      setError("Paste a 0x Sepolia address (40 hex chars).");
      return;
    }
    setBusy(true);
    setError(null);
    const res = await onFaucet(next);
    setBusy(false);
    if (res.error) {
      setError(res.error);
      return;
    }
    if (res.address && res.usdcTx && res.ethTx) {
      setResult({
        address: res.address,
        usdcTx: res.usdcTx,
        ethTx: res.ethTx,
      });
    }
  };

  return (
    <div className="mx-auto mt-10 w-full max-w-[480px] border-t hair pt-6 md:ml-[8%] md:mr-auto">
      <div className="label-kicker">Sepolia faucet</div>
      <p className="mt-2 text-[13px] leading-relaxed text-uni-muted">
        Fund your own Sepolia address. Mints 10,000 MockUSDC + 1 MockWETH.
        Does not connect that wallet or change A–E. A new address is
        never-scored until a keeper publishes a row.
      </p>
      <input
        type="text"
        spellCheck={false}
        autoComplete="off"
        placeholder="0x…"
        value={address}
        onChange={(e) => setAddress(e.target.value)}
        className="mt-4 w-full border-b hair bg-transparent py-2 font-mono text-sm text-uni-pink placeholder:text-uni-muted/50"
      />
      <button
        type="button"
        disabled={busy}
        onClick={() => void handleMint()}
        className="radius-action edge mt-4 w-full bg-transparent py-3 text-center text-sm font-medium text-uni-pink transition hover:bg-uni-pink/5 disabled:cursor-not-allowed disabled:opacity-40"
      >
        {busy ? "Minting…" : "Mint 10,000 USDC + 1 ETH"}
      </button>
      {error && (
        <p className="mt-2 text-center text-xs text-uni-bad">{error}</p>
      )}
      {result && (
        <p className="mt-2 break-all text-center text-[11px] text-uni-muted">
          Sent to {shorten(result.address)}. USDC {shorten(result.usdcTx)} · ETH{" "}
          {shorten(result.ethTx)}
        </p>
      )}
    </div>
  );
}
