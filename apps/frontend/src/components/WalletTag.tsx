"use client";

import type { SimWallet } from "@/lib/hopScoring";

export type WalletTone = {
  border: string;
  bg: string;
  text: string;
  badge: string;
  label: string;
};

/**
 * Icon / border accent from live ledger (NOT from swap count):
 * - Exploit (A) → red
 * - B/C/D with no inbound hop → green / score 0 (clean swaps stay green)
 * - Wallet D keeper pending (latency window) → yellow · inflow
 * - Hop 1 (A→B/C/D after catch-up) → yellow · ~65 · 8%
 * - Hop 2 (tainted B→C or C→B) → yellow · ~42 · 3%
 */
export function walletTone(wallet: SimWallet): WalletTone {
  if (wallet.exploitConfirmed) {
    return {
      border: "border-uni-bad",
      bg: "bg-uni-bad/10",
      text: "text-uni-bad",
      badge: "bg-uni-bad text-black",
      label: "Exploit",
    };
  }

  if (wallet.keeperPending) {
    return {
      border: "border-uni-warn",
      bg: "bg-uni-warn/10",
      text: "text-uni-warn",
      badge: "bg-uni-warn text-black",
      label: "Latency",
    };
  }

  // Only turn yellow once contaminated by an inbound transfer (A→B, C→B, etc.)
  const contaminated =
    typeof wallet.hopDistance === "number" && wallet.hopDistance >= 1;

  if (contaminated) {
    return {
      border: "border-uni-warn",
      bg: "bg-uni-warn/10",
      text: "text-uni-warn",
      badge: "bg-uni-warn text-black",
      label: `${wallet.hopDistance}-hop`,
    };
  }

  return {
    border: "border-uni-ok",
    bg: "bg-uni-ok/10",
    text: "text-uni-ok",
    badge: "bg-uni-ok text-black",
    label: wallet.id === "D" ? "Latency path" : "Clean",
  };
}
