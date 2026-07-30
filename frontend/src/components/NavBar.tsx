"use client";

type Props = {
  /** Whether a demo wallet is currently connected to Uniswap */
  connected: boolean;
  /** Connected wallet address, or null if disconnected */
  address: string | null;
  /** Active demo wallet id (A / B / C), shown on the connect chip */
  walletId?: string | null;
  /** Border class for risk tone: green / yellow / red */
  riskBorderClass?: string;
  /** Opens the classic connect-wallet modal */
  onConnectClick: () => void;
  /** Opens the MetaMask transfer-simulation sheet (slides in from the right) */
  onMetaMaskClick: () => void;
  /** Reseeds ledger + demo UI to use-case baseline */
  onRestartData?: () => void;
};

/**
 * Shortens an Ethereum address for the navbar chip (0x1234…abcd).
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Top navigation: Uniswap + Connect (risk-colored border) · Restart data · MetaMask.
 */
export function NavBar({
  connected,
  address,
  walletId,
  riskBorderClass,
  onConnectClick,
  onMetaMaskClick,
  onRestartData,
}: Props) {
  const connectedLabel =
    connected && address
      ? walletId
        ? `${walletId} · ${shorten(address)}`
        : shorten(address)
      : "Connect";

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
          title={connected ? "Switch wallet" : "Connect wallet"}
          className={`rounded-full px-4 py-2.5 text-sm font-semibold transition ${
            connected
              ? `border-2 bg-uni-card text-white hover:bg-uni-cardHover ${riskBorderClass ?? "border-uni-border"}`
              : "bg-uni-pink text-black hover:brightness-110"
          }`}
        >
          {connectedLabel}
        </button>
      </div>

      <div className="ml-auto flex items-center gap-2">
        {onRestartData ? (
          <button
            type="button"
            onClick={onRestartData}
            data-no-stage-nav
            title="Restart data"
            aria-label="Restart data"
            className="inline-flex items-center gap-2 rounded-full border border-white/20 bg-[#1a1a1e] px-3 py-2 text-sm font-semibold text-white transition hover:bg-[#25252b]"
          >
            <span
              className="flex h-7 w-7 items-center justify-center rounded-full border border-white/25 bg-[#2a2a2e]"
              aria-hidden
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M21 12a9 9 0 1 1-2.6-6.3" />
                <polyline points="21 3 21 9 15 9" />
              </svg>
            </span>
            <span className="hidden sm:inline">Restart data</span>
          </button>
        ) : null}
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
