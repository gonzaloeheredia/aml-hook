"use client";

import { ThemeSwitch } from "@/components/ThemeSwitch";

type Props = {
  /** Whether a demo wallet is currently connected to Uniswap */
  connected: boolean;
  /** Connected wallet address, or null if disconnected */
  address: string | null;
  /** Active demo wallet id (A–E), shown on the connect chip */
  walletId?: string | null;
  /** Border class for risk tone: green / yellow / red */
  riskBorderClass?: string;
  /** Opens the classic connect-wallet modal */
  onConnectClick: () => void;
  /** Opens the MetaMask transfer-simulation sheet (slides in from the right) */
  onMetaMaskClick: () => void;
};

/**
 * Top navigation: Uniswap left · text link + Connect pill right.
 */
export function NavBar({
  connected,
  address,
  onConnectClick,
  onMetaMaskClick,
}: Props) {
  return (
    <header className="relative z-20 flex min-h-14 items-center gap-4 border-b hair py-3 md:min-h-16 md:py-4">
      <div className="flex min-w-0 items-center gap-8">
        <img
          src="/uniswap-logo.svg"
          alt="Uniswap"
          className="h-7 w-auto shrink-0 md:h-8"
        />
        <button
          type="button"
          onClick={onMetaMaskClick}
          className="bg-transparent text-[15px] font-medium text-uni-muted transition hover:text-uni-pink"
          title="Open MetaMask transfer simulator"
        >
          MetaMask Simulator
        </button>
      </div>

      <div className="ml-auto flex items-center gap-4">
        <ThemeSwitch />
        <button
          type="button"
          onClick={onConnectClick}
          title={
            connected
              ? address
                ? `Switch wallet · ${address}`
                : "Switch wallet"
              : "Connect wallet"
          }
          className="rounded-full bg-[#FC72FF] px-5 py-2 text-[15px] font-semibold text-black transition hover:brightness-110"
        >
          Connect
        </button>
      </div>
    </header>
  );
}
