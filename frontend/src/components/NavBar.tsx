"use client";

type Props = {
  /** Whether a demo wallet is currently connected to Uniswap */
  connected: boolean;
  /** Connected wallet address, or null if disconnected */
  address: string | null;
  /** Opens the classic connect-wallet modal */
  onConnectClick: () => void;
  /** Opens the MetaMask transfer-simulation sheet (slides in from the right) */
  onMetaMaskClick: () => void;
};

/**
 * Shortens an Ethereum address for the navbar chip (0x1234…abcd).
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Top navigation: Uniswap + Connect (left) · MetaMask sim entry (right, former Connect slot).
 */
export function NavBar({
  connected,
  address,
  onConnectClick,
  onMetaMaskClick,
}: Props) {
  return (
    <header className="relative z-20 flex min-h-16 items-center gap-4 py-5 md:min-h-[4.5rem] md:py-6">
      <div className="flex shrink-0 items-center gap-3">
        <span className="text-2xl" aria-hidden>
          🦄
        </span>
        <span className="text-lg font-semibold tracking-tight">Uniswap</span>
        <button
          type="button"
          onClick={onConnectClick}
          className={`rounded-full px-4 py-2.5 text-sm font-semibold transition ${
            connected
              ? "border border-uni-border bg-uni-card text-white hover:bg-uni-cardHover"
              : "bg-uni-pink text-black hover:brightness-110"
          }`}
        >
          {connected && address ? shorten(address) : "Connect"}
        </button>
      </div>

      <div className="ml-auto">
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
      </div>
    </header>
  );
}
