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
 * - Exploit / score 100 (A) → red
 * - Wallet E unknown → yellow · unknown
 * - B/C/D with no inbound hop → green / score 0
 * - Wallet D keeper pending → yellow · inflow
 * - Hop 1 → yellow · ~65 · 8%
 * - Hop 2 → yellow · ~42 · 3%
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

  if (wallet.neverScored) {
    return {
      border: "border-uni-warn",
      bg: "bg-uni-warn/10",
      text: "text-uni-warn",
      badge: "bg-uni-warn text-black",
      label: "Unknown",
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
    label: wallet.id === "D" ? "Score 0" : "Clean",
  };
}
