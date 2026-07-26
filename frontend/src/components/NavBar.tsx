"use client";

type Props = {
  /** Whether a demo wallet is currently connected */
  connected: boolean;
  /** Connected wallet address, or null if disconnected */
  address: string | null;
  /** Opens the connect-wallet modal */
  onConnectClick: () => void;
};

/**
 * Shortens an Ethereum address for the navbar chip (0x1234…abcd).
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Top navigation bar: Uniswap branding + AML Hook badge + connect button.
 * Search and trade menu items are intentionally omitted for this demo.
 */
export function NavBar({ connected, address, onConnectClick }: Props) {
  return (
    <header className="relative z-20 flex min-h-16 items-center gap-4 py-5 md:min-h-[4.5rem] md:py-6">
      <div className="flex shrink-0 items-center gap-2">
        <span className="text-2xl" aria-hidden>
          🦄
        </span>
        <span className="text-lg font-semibold tracking-tight">Uniswap</span>
        <span className="ml-1 hidden rounded-full border border-uni-pink/30 bg-uni-pink/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-uni-pink sm:inline">
          AML Hook
        </span>
      </div>

      <div className="ml-auto flex items-center gap-2">
        <button
          type="button"
          className="hidden h-10 w-10 items-center justify-center rounded-full border border-uni-border bg-uni-surface text-uni-muted sm:flex"
          aria-label="More"
        >
          ···
        </button>
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
    </header>
  );
}
