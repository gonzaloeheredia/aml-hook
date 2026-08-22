"use client";

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
 * Top navigation: Uniswap left · MetaMask + Connect right (official layout).
 */
export function NavBar({
  connected,
  address,
  walletId,
  riskBorderClass,
  onConnectClick,
  onMetaMaskClick,
}: Props) {
  const connectedLabel =
    connected && walletId ? `Wallet ${walletId}` : "Connect";

  return (
    <header className="relative z-20 flex min-h-16 items-center gap-4 py-5 md:min-h-[4.5rem] md:py-6">
      <div className="flex shrink-0 items-center">
        <img
          src="/uniswap-logo.svg"
          alt="Uniswap"
          className="h-7 w-auto md:h-8"
        />
      </div>

      <div className="ml-auto flex items-center gap-2">
        <button
          type="button"
          onClick={onMetaMaskClick}
          className="flex items-center gap-2 rounded-full border border-[#037DD6]/35 bg-[#037DD6]/15 px-3 py-2 text-sm font-semibold text-[#8BCAFF] transition hover:bg-[#037DD6]/25"
          title="Open MetaMask transfer simulator"
        >
          <span className="text-base" aria-hidden>
            🦊
          </span>
          <span className="hidden sm:inline">MetaMask Simulator</span>
        </button>
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
          className={`rounded-full px-4 py-2.5 text-sm font-semibold transition ${
            connected
              ? `border-2 bg-uni-card text-white hover:bg-uni-cardHover ${riskBorderClass ?? "border-uni-border"}`
              : "bg-uni-pink text-black hover:brightness-110"
          }`}
        >
          {connectedLabel}
        </button>
      </div>
    </header>
  );
}
