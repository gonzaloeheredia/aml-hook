"use client";

import { useEffect, useRef, useState } from "react";
import { ThemeSwitch } from "@/components/ThemeSwitch";

export type AppView = "hook" | "whitepaper" | "use-of-case";

type Props = {
  /** Current document / demo view */
  view: AppView;
  /** Switches hook / whitepaper / use of case */
  onViewChange: (view: AppView) => void;
  /** Whether a demo wallet is currently connected to Uniswap */
  connected: boolean;
  /** Connected wallet address, or null if disconnected */
  address: string | null;
  /** Active demo wallet id (A–E / N), shown on the connect chip */
  walletId?: string | null;
  /** Border class for risk tone: green / yellow / red */
  riskBorderClass?: string;
  /** Opens the classic connect-wallet modal */
  onConnectClick: () => void;
  /** Disconnects the demo wallet from the pool */
  onDisconnect: () => void;
  /** Opens the MetaMask transfer-simulation sheet (slides in from the right) */
  onMetaMaskClick: () => void;
};

const VIEWS: { id: AppView; label: string }[] = [
  { id: "hook", label: "Hook" },
  { id: "whitepaper", label: "Whitepaper" },
  { id: "use-of-case", label: "Use of case" },
];

/**
 * Shortens a hex address for the connected chip and menu.
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Label for the navbar connect chip.
 */
function accountLabel(walletId?: string | null) {
  if (walletId === "N") return "New wallet";
  if (walletId) return `Wallet ${walletId}`;
  return "Connected";
}

/**
 * Top navigation: Uniswap left · view links + MetaMask + Connect right.
 */
export function NavBar({
  view,
  onViewChange,
  connected,
  address,
  walletId,
  onConnectClick,
  onDisconnect,
  onMetaMaskClick,
}: Props) {
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!connected) setMenuOpen(false);
  }, [connected]);

  useEffect(() => {
    if (!menuOpen) return;

    const onPointerDown = (event: MouseEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) {
        setMenuOpen(false);
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setMenuOpen(false);
    };

    document.addEventListener("mousedown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("mousedown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [menuOpen]);

  return (
    <header className="relative z-20 flex min-h-14 items-center gap-4 border-b hair py-3 md:min-h-16 md:py-4">
      <div className="flex min-w-0 flex-wrap items-center gap-x-6 gap-y-2 md:gap-x-8">
        <img
          src="/uniswap-logo.svg"
          alt="Uniswap"
          className="h-7 w-auto shrink-0 md:h-8"
        />
        {VIEWS.map((item) => {
          const active = view === item.id;
          return (
            <button
              key={item.id}
              type="button"
              onClick={() => onViewChange(item.id)}
              aria-current={active ? "page" : undefined}
              className={`bg-transparent text-[15px] font-medium transition ${
                active
                  ? "text-uni-pink"
                  : "text-uni-muted hover:text-uni-pink"
              }`}
            >
              {item.label}
            </button>
          );
        })}
        <button
          type="button"
          onClick={onMetaMaskClick}
          className="bg-transparent text-[15px] font-medium text-uni-muted transition hover:text-uni-pink"
          title="Open MetaMask transfer simulator"
        >
          MetaMask Simulator
        </button>
      </div>

      <div className="ml-auto flex shrink-0 items-center gap-4">
        <ThemeSwitch />
        {connected ? (
          <div className="relative" ref={menuRef}>
            <button
              type="button"
              aria-expanded={menuOpen}
              aria-haspopup="menu"
              onClick={() => setMenuOpen((open) => !open)}
              title={address ? `${accountLabel(walletId)} · ${address}` : accountLabel(walletId)}
              className="rounded-full bg-[#FC72FF] px-5 py-2 text-[15px] font-semibold text-black transition hover:brightness-110"
            >
              {accountLabel(walletId)}
            </button>
            {menuOpen && (
              <div
                role="menu"
                className="surface radius-b absolute right-0 top-full z-30 mt-2 min-w-[11.5rem] border-l hair py-2"
              >
                {address && (
                  <p className="px-4 pb-2 font-mono text-[11px] text-uni-muted">
                    {shorten(address)}
                  </p>
                )}
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    setMenuOpen(false);
                    onConnectClick();
                  }}
                  className="block w-full px-4 py-2 text-left text-[15px] font-medium text-uni-muted transition hover:text-uni-pink"
                >
                  Switch wallet
                </button>
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    setMenuOpen(false);
                    onDisconnect();
                  }}
                  className="block w-full px-4 py-2 text-left text-[15px] font-medium text-uni-muted transition hover:text-uni-pink"
                >
                  Disconnect
                </button>
              </div>
            )}
          </div>
        ) : (
          <button
            type="button"
            onClick={onConnectClick}
            title="Connect wallet"
            className="rounded-full bg-[#FC72FF] px-5 py-2 text-[15px] font-semibold text-black transition hover:brightness-110"
          >
            Connect
          </button>
        )}
      </div>
    </header>
  );
}
