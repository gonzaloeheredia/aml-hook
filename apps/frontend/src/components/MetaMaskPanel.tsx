"use client";

import { useEffect, useMemo, useState } from "react";
import {
  ETH_USD,
  bandLabelForUsd,
  dustExampleUsd,
  inflowAmountPresets,
  inflowBandLabel,
  unknownFundPresets,
  isSenderTainted,
  previewTransfer,
  type SimWallet,
  type SimWalletId,
} from "@/lib/hopScoring";
import { walletTone } from "@/components/WalletTag";

type Props = {
  open: boolean;
  onClose: () => void;
  wallets: Record<SimWalletId, SimWallet>;
  activeId: SimWalletId;
  onActiveChange: (id: SimWalletId) => void;
  /**
   * Posts a P2P transfer to the backend and updates local ledger state.
   * Returns an error message on failure.
   */
  onSendTransfer: (
    from: SimWalletId,
    to: SimWalletId,
    amountUsd: number,
  ) => Promise<string | null>;
  /** Connects the active MetaMask account into the Uniswap demo */
  onUseInUniswap: (id: SimWalletId) => void;
  /** Mints MockUSDC or MockWETH to the active demo wallet. */
  onMint: (
    id: SimWalletId,
    token: "usdc" | "eth",
    amount: number,
  ) => Promise<string | null>;
  /** Judge faucet: mint 10,000 MockUSDC + 1 MockWETH to a pasted Sepolia address. */
  onFaucet: (address: string) => Promise<{
    error: string | null;
    usdcTx?: string;
    ethTx?: string;
    address?: string;
  }>;
  /** Optional API connectivity hint shown in the panel header */
  apiLabel?: string | null;
};

type View = "home" | "accounts" | "send";

/**
 * Formats USD for MetaMask-style balance rows (whole dollars).
 */
function formatUsd(n: number) {
  return n.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  });
}

/**
 * Formats a whole USDC amount without currency symbol.
 */
function formatUsdc(n: number) {
  return `${Math.round(n).toLocaleString("en-US")} USDC`;
}

/**
 * Shortens an address for list rows.
 */
function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * MetaMask-inspired wallet sheet that slides in from the right.
 * P2P sends debit the sender and credit the recipient in shared ledger state.
 */
export function MetaMaskPanel({
  open,
  onClose,
  wallets,
  activeId,
  onActiveChange,
  onSendTransfer,
  onUseInUniswap,
  onMint,
  onFaucet,
  apiLabel,
}: Props) {
  const [view, setView] = useState<View>("home");
  const [toId, setToId] = useState<SimWalletId>("B");
  const [amount, setAmount] = useState("10000");
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [minting, setMinting] = useState<"usdc" | "eth" | null>(null);
  const [mintTarget, setMintTarget] = useState<"self" | "other">("self");
  const [faucetAddress, setFaucetAddress] = useState("");
  const [faucetBusy, setFaucetBusy] = useState(false);
  const [faucetError, setFaucetError] = useState<string | null>(null);
  const [faucetResult, setFaucetResult] = useState<{
    address: string;
    usdcTx: string;
    ethTx: string;
  } | null>(null);
  const [lastMove, setLastMove] = useState<{
    from: SimWalletId;
    to: SimWalletId;
    amount: number;
  } | null>(null);

  const active = wallets[activeId];
  const totalUsd = active.usdc + active.eth * ETH_USD;

  const recipients = useMemo(
    () =>
      (Object.keys(wallets) as SimWalletId[]).filter((id) => id !== activeId),
    [wallets, activeId],
  );

  /** Prefer C→E when E is empty; C→D for inflow; A→B for hop. */
  useEffect(() => {
    if (activeId === "C") setToId(wallets.E.usdc <= 0 ? "E" : "D");
    else if (activeId === "B" && !isSenderTainted(wallets.B)) setToId("D");
    else if (activeId === "A") setToId("B");
    else setToId((prev) => (prev === activeId ? "C" : prev));
  }, [activeId, wallets.B, wallets.E.usdc]);

  /** Clear flash when switching accounts */
  useEffect(() => {
    setLastMove(null);
    setError(null);
    setMintTarget("self");
  }, [activeId]);

  const parsedAmount = Math.round(Number(String(amount).replace(/,/g, "")));
  const amountOk = Number.isFinite(parsedAmount) && parsedAmount > 0;
  const canSend =
    amountOk &&
    parsedAmount <= active.usdc &&
    toId !== activeId &&
    !!wallets[toId];

  /**
   * Confirms a USDC transfer via the backend API ledger.
   */
  const handleSend = async () => {
    if (!amountOk) {
      setError("Enter a valid whole-USDC amount");
      return;
    }
    if (parsedAmount > active.usdc) {
      setError(`Insufficient USDC — available ${formatUsdc(active.usdc)}`);
      return;
    }
    setSending(true);
    setError(null);
    const err = await onSendTransfer(activeId, toId, parsedAmount);
    setSending(false);
    if (err) {
      setError(err);
      return;
    }
    setLastMove({ from: activeId, to: toId, amount: parsedAmount });
    setAmount("10000");
    setView("home");
  };

  const handleMint = async (token: "usdc" | "eth", amount: number) => {
    setMinting(token);
    setError(null);
    const err = await onMint(activeId, token, amount);
    setMinting(null);
    if (err) setError(err);
  };

  const handleFaucet = async () => {
    const next = faucetAddress.trim();
    if (!/^0x[a-fA-F0-9]{40}$/.test(next)) {
      setFaucetError("Paste a 0x Sepolia address (40 hex chars).");
      return;
    }
    setFaucetBusy(true);
    setFaucetError(null);
    const res = await onFaucet(next);
    setFaucetBusy(false);
    if (res.error) {
      setFaucetError(res.error);
      return;
    }
    if (res.address && res.usdcTx && res.ethTx) {
      setFaucetResult({
        address: res.address,
        usdcTx: res.usdcTx,
        ethTx: res.ethTx,
      });
    }
  };

  const hasUsdc = active.usdc > 0;
  const mintPrimary = !hasUsdc;

  return (
    <div
      className={`fixed inset-0 z-[60] ${open ? "pointer-events-auto" : "pointer-events-none"}`}
      aria-hidden={!open}
    >
      <button
        type="button"
        aria-label="Close wallet"
        className={`absolute inset-0 bg-black/55 backdrop-blur-[2px] transition-opacity duration-300 ${
          open ? "opacity-100" : "opacity-0"
        }`}
        onClick={onClose}
      />

      <aside
        className={`absolute inset-y-0 right-0 flex w-full max-w-[420px] justify-end transition-transform duration-500 ease-out ${
          open ? "translate-x-0" : "translate-x-full"
        }`}
      >
        <div className="flex h-full w-full flex-col overflow-hidden border-l border-white/10 bg-[#0B0B0C] shadow-[-24px_0_80px_rgba(0,0,0,0.55)] sm:m-3 sm:h-[calc(100%-1.5rem)] sm:max-w-[380px] sm:border">
          {/* Header */}
          <div className="border-b border-white/10 px-4 py-3">
            <div className="flex items-center justify-between">
              <button
                type="button"
                onClick={() => setView(view === "accounts" ? "home" : "accounts")}
                className="flex items-center gap-2 rounded-full px-2 py-1 text-sm font-semibold text-white hover:bg-white/5"
              >
              <span
                className={`flex h-7 w-7 items-center justify-center rounded-full text-sm font-bold ${walletTone(active).badge}`}
              >
                {activeId}
              </span>
                <span className="max-w-[9rem] truncate">{active.accountLabel}</span>
                <span className="text-white/40">▾</span>
              </button>
              <button
                type="button"
                onClick={onClose}
                className="rounded-full px-2 py-1 text-white/50 hover:bg-white/5 hover:text-white"
              >
                ✕
              </button>
            </div>
            {apiLabel && (
              <p className="mt-1 truncate px-2 text-[10px] text-white/35">{apiLabel}</p>
            )}
          </div>

          {view === "accounts" ? (
            <div className="flex-1 overflow-y-auto p-4">
              <p className="mb-3 text-xs uppercase tracking-wider text-white/40">
                Demo accounts · live USDC balances
              </p>
              <div className="space-y-2">
                {(Object.keys(wallets) as SimWalletId[]).map((id) => {
                  const w = wallets[id];
                  const tone = walletTone(w);
                  return (
                    <button
                      key={id}
                      type="button"
                      onClick={() => {
                        onActiveChange(id);
                        setView("home");
                      }}
                      className={`flex w-full items-center gap-3 rounded-2xl border px-3 py-3 text-left transition ${
                        id === activeId
                          ? `${tone.border} ${tone.bg}`
                          : "border-white/10 bg-white/[0.03] hover:bg-white/[0.06]"
                      }`}
                    >
                      <span
                        className={`flex h-10 w-10 items-center justify-center rounded-full text-sm font-bold ${tone.badge}`}
                      >
                        {id}
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block text-sm font-semibold text-white">
                          {w.accountLabel}
                        </span>
                        <span className={`block text-[11px] ${tone.text}`}>
                          {tone.label}
                        </span>
                        <span className="block truncate font-mono text-[11px] text-white/45">
                          {shorten(w.address)}
                        </span>
                      </span>
                      <span className="shrink-0 text-right">
                        <span className="block text-sm font-semibold text-white">
                          {formatUsdc(w.usdc)}
                        </span>
                        <span className="block text-[11px] text-white/45">
                          {formatUsd(w.usdc + w.eth * ETH_USD)}
                        </span>
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          ) : view === "send" ? (
            <div className="flex flex-1 flex-col overflow-y-auto p-4">
              <button
                type="button"
                onClick={() => setView("home")}
                className="mb-4 text-left text-sm text-white/50 hover:text-white"
              >
                ← Back
              </button>
              <h3 className="text-xl font-bold text-white">Send USDC</h3>
              <p className="mt-1 text-sm text-white/50">
                Moves USDC between A–E. For D inflow (no hop), send from C while C is still clean — not from A.
              </p>

              <label className="mt-6 text-[11px] uppercase tracking-wider text-white/40">
                From
              </label>
              <div className="mt-1 rounded-2xl border border-white/10 bg-white/[0.04] px-3 py-3 text-sm text-white">
                {active.accountLabel}
                <div className="font-mono text-xs text-white/45">{shorten(active.address)}</div>
                <div className="mt-1 text-xs text-white/55">
                  Available {formatUsdc(active.usdc)}
                </div>
              </div>

              <label className="mt-4 text-[11px] uppercase tracking-wider text-white/40">
                To
              </label>
              <div className="mt-1 grid grid-cols-2 gap-2">
                {recipients.map((id) => (
                  <button
                    key={id}
                    type="button"
                    onClick={() => setToId(id)}
                    className={`rounded-2xl border px-3 py-3 text-left text-sm ${
                      toId === id
                        ? "border-[#037DD6] bg-[#037DD6]/15 text-white"
                        : "border-white/10 bg-white/[0.04] text-white/70"
                    }`}
                  >
                    Account {id}
                    <div className="font-mono text-[10px] opacity-60">
                      {shorten(wallets[id].address)}
                    </div>
                    <div className="mt-1 text-[11px] font-medium opacity-80">
                      {formatUsdc(wallets[id].usdc)}
                      {id === "D" && !isSenderTainted(active)
                        ? " · inflow"
                        : id === "D" && isSenderTainted(active)
                          ? " · hop"
                          : ""}
                    </div>
                  </button>
                ))}
              </div>

              <label className="mt-4 flex items-center justify-between text-[11px] uppercase tracking-wider text-white/40">
                <span>Amount (USDC)</span>
                <button
                  type="button"
                  className="normal-case tracking-normal text-[#8BCAFF] hover:underline"
                  onClick={() => setAmount(String(Math.floor(active.usdc)))}
                >
                  Max
                </button>
              </label>
              <input
                value={amount}
                onChange={(e) => setAmount(e.target.value.replace(/[^\d]/g, ""))}
                inputMode="numeric"
                className="mt-1 w-full rounded-2xl border border-white/10 bg-white/[0.04] px-4 py-3 text-lg text-white outline-none focus:border-[#037DD6]"
              />
              {toId === "D" && (
                <div className="mt-2 flex flex-wrap gap-2">
                  {inflowAmountPresets().map((preset) => (
                    <button
                      key={preset}
                      type="button"
                      onClick={() => setAmount(String(preset))}
                      className={`rounded-full px-3 py-1 text-xs font-semibold ${
                        parsedAmount === preset
                          ? "bg-[#037DD6] text-white"
                          : "bg-white/10 text-white/70 hover:text-white"
                      }`}
                    >
                      ${preset.toLocaleString("en-US")}
                      {` · ${inflowBandLabel(preset)}`}
                    </button>
                  ))}
                </div>
              )}
              {toId === "E" && (
                <div className="mt-2 flex flex-wrap gap-2">
                  {unknownFundPresets().map((preset) => {
                    const nextBag = wallets.E.usdc + preset;
                    return (
                      <button
                        key={preset}
                        type="button"
                        onClick={() => setAmount(String(preset))}
                        className={`rounded-full px-3 py-1 text-xs font-semibold ${
                          parsedAmount === preset
                            ? "bg-[#037DD6] text-white"
                            : "bg-white/10 text-white/70 hover:text-white"
                        }`}
                      >
                        ${preset.toLocaleString("en-US")}
                        {` · ${bandLabelForUsd(dustExampleUsd(), nextBag)} next swap`}
                      </button>
                    );
                  })}
                </div>
              )}

              {amountOk && canSend && (
                <div className="mt-3 rounded-2xl border border-white/10 bg-white/[0.03] px-3 py-3 text-xs text-white/70">
                  <div className="flex justify-between gap-2">
                    <span>{activeId} after</span>
                    <span className="font-medium text-white">
                      {formatUsdc(active.usdc - parsedAmount)}
                    </span>
                  </div>
                  <div className="mt-1 flex justify-between gap-2">
                    <span>{toId} after</span>
                    <span className="font-medium text-white">
                      {formatUsdc(wallets[toId].usdc + parsedAmount)}
                    </span>
                  </div>
                  {(() => {
                    const preview = previewTransfer(active, wallets[toId], parsedAmount);
                    const color =
                      preview.tone === "bad"
                        ? "text-[#FF6B6B]"
                        : preview.tone === "warn"
                          ? "text-[#F0B90B]"
                          : "text-[#28A745]";
                    return (
                      <div className={`mt-2 border-t border-white/10 pt-2 ${color}`}>
                        <div className="font-semibold">{preview.title}</div>
                        <div className="mt-0.5 opacity-90">{preview.detail}</div>
                      </div>
                    );
                  })()}
                </div>
              )}

              {error && <p className="mt-2 text-sm text-[#FF6B6B]">{error}</p>}

              <button
                type="button"
                onClick={() => void handleSend()}
                disabled={!canSend || sending}
                className="mt-6 w-full rounded-full bg-[#037DD6] py-3.5 text-sm font-semibold text-white hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-40"
              >
                {sending ? "Sending…" : "Confirm transfer"}
              </button>
            </div>
          ) : (
            <div className="flex flex-1 flex-col overflow-y-auto">
              <div className="px-5 pb-2 pt-6 text-center">
                <div className="text-4xl font-bold tracking-tight text-white">
                  {formatUsd(totalUsd)}
                </div>
                <div className="mt-1 text-sm text-[#28A745]">
                  {active.hopDistance == null && !active.exploitConfirmed
                    ? "Clean ledger · ready for baseline swap"
                    : active.exploitConfirmed
                      ? "Exploit confirmed · pool will REVERT"
                      : `${active.hopDistance}-hop contamination · fee override expected`}
                </div>
                {lastMove && (lastMove.from === activeId || lastMove.to === activeId) && (
                  <div className="mt-3 rounded-full bg-white/5 px-3 py-1.5 text-xs text-white/70">
                    {lastMove.from === activeId ? (
                      <span>
                        Sent −{lastMove.amount.toLocaleString("en-US")} USDC → {lastMove.to}
                      </span>
                    ) : (
                      <span>
                        Received +{lastMove.amount.toLocaleString("en-US")} USDC from{" "}
                        {lastMove.from}
                      </span>
                    )}
                  </div>
                )}
              </div>

              <div className="mt-6 px-4 pb-2">
                <div className="mb-2 text-sm font-semibold text-white">Tokens</div>
                <div className="space-y-1 rounded-2xl border border-white/10 bg-[#121214] p-1">
                  <TokenRow
                    symbol="USDC"
                    name="Mock USDC"
                    amount={formatUsdc(active.usdc)}
                    usd={formatUsd(active.usdc)}
                    tone="#2775CA"
                    hint={active.usdc <= 0 ? "No funds. Mint to get started" : undefined}
                  />
                  <TokenRow
                    symbol="ETH"
                    name="Mock ETH"
                    amount={`${Number(active.eth.toFixed(4))} ETH`}
                    usd={formatUsd(active.eth * ETH_USD)}
                    tone="#627EEA"
                    hint={active.eth <= 0 ? "No funds. Mint to get started" : undefined}
                  />
                </div>

                <div className="mt-5">
                  <div className="mb-2 text-sm font-semibold text-white">Mint tokens</div>
                  <div className="rounded-2xl border border-white/10 bg-[#121214] p-2">
                    <div className="grid grid-cols-2 gap-1 rounded-xl bg-[#1A1A1C] p-1">
                      <button
                        type="button"
                        onClick={() => setMintTarget("self")}
                        className={`rounded-lg py-2 text-xs font-semibold transition ${
                          mintTarget === "self"
                            ? "bg-white text-black"
                            : "text-white/50 hover:text-white"
                        }`}
                      >
                        This account
                      </button>
                      <button
                        type="button"
                        onClick={() => setMintTarget("other")}
                        className={`rounded-lg py-2 text-xs font-semibold transition ${
                          mintTarget === "other"
                            ? "bg-white text-black"
                            : "text-white/50 hover:text-white"
                        }`}
                      >
                        Another address
                      </button>
                    </div>

                    {mintTarget === "self" ? (
                      <div className="mt-2 grid grid-cols-2 gap-2">
                        <button
                          type="button"
                          disabled={minting !== null}
                          onClick={() => void handleMint("usdc", 10_000)}
                          className={`rounded-2xl px-3 py-2.5 text-xs font-semibold disabled:opacity-40 ${
                            mintPrimary
                              ? "bg-[#E8E4D9] text-black hover:brightness-110"
                              : "border border-white/10 bg-[#1A1A1C] text-white hover:bg-[#242426]"
                          }`}
                        >
                          {minting === "usdc" ? "Minting…" : "Mint 10,000 USDC"}
                        </button>
                        <button
                          type="button"
                          disabled={minting !== null}
                          onClick={() => void handleMint("eth", 1)}
                          className={`rounded-2xl px-3 py-2.5 text-xs font-semibold disabled:opacity-40 ${
                            mintPrimary
                              ? "bg-[#E8E4D9] text-black hover:brightness-110"
                              : "border border-white/10 bg-[#1A1A1C] text-white hover:bg-[#242426]"
                          }`}
                        >
                          {minting === "eth" ? "Minting…" : "Mint 1 ETH"}
                        </button>
                      </div>
                    ) : (
                      <div className="mt-3 px-1 pb-1">
                        <p className="text-[11px] leading-snug text-white/40">
                          Paste a public Sepolia address. Mints 10,000 MockUSDC + 1
                          MockWETH. Does not connect that wallet here. A new address
                          is never-scored on the pool until a keeper publishes a row.
                        </p>
                        <input
                          type="text"
                          spellCheck={false}
                          autoComplete="off"
                          placeholder="0x…"
                          value={faucetAddress}
                          onChange={(e) => setFaucetAddress(e.target.value)}
                          className="mt-2 w-full rounded-2xl border border-white/10 bg-[#0B0B0C] px-3 py-2.5 font-mono text-xs text-white placeholder:text-white/25"
                        />
                        <button
                          type="button"
                          disabled={faucetBusy}
                          onClick={() => void handleFaucet()}
                          className="mt-2 w-full rounded-2xl border border-white/10 bg-[#1A1A1C] px-3 py-2.5 text-xs font-semibold text-white hover:bg-[#242426] disabled:opacity-40"
                        >
                          {faucetBusy
                            ? "Minting…"
                            : "Mint 10,000 USDC + 1 ETH"}
                        </button>
                        {faucetError && (
                          <p className="mt-2 text-center text-xs text-[#FF6B6B]">
                            {faucetError}
                          </p>
                        )}
                        {faucetResult && (
                          <p className="mt-2 break-all text-center text-[11px] text-white/45">
                            Sent to {shorten(faucetResult.address)}. USDC{" "}
                            {shorten(faucetResult.usdcTx)} · ETH{" "}
                            {shorten(faucetResult.ethTx)}
                          </p>
                        )}
                      </div>
                    )}
                  </div>
                </div>
                {error && view === "home" && (
                  <p className="mt-2 text-center text-xs text-[#FF6B6B]">{error}</p>
                )}
              </div>

              <div className="mt-4 px-4">
                {hasUsdc ? (
                  <button
                    type="button"
                    onClick={() => {
                      setError(null);
                      setView("send");
                    }}
                    className="flex w-full flex-col items-center gap-2 rounded-2xl bg-[#E8E4D9] px-2 py-3 text-black transition hover:brightness-110"
                  >
                    <span className="flex h-10 w-10 items-center justify-center rounded-full bg-black/10 text-base">
                      ➤
                    </span>
                    <span className="text-[11px] font-semibold">Send USDC (P2P)</span>
                  </button>
                ) : (
                  <button
                    type="button"
                    onClick={() => {
                      setError(null);
                      setView("send");
                    }}
                    className="w-full rounded-2xl border border-white/10 bg-transparent py-3 text-xs font-medium text-white/40 transition hover:bg-white/[0.04] hover:text-white/60"
                  >
                    Send USDC (P2P)
                  </button>
                )}
              </div>

              <div className="mt-auto border-t border-white/10 p-4">
                <button
                  type="button"
                  onClick={() => onUseInUniswap(activeId)}
                  className="w-full rounded-2xl bg-[#E8E4D9] py-3.5 text-sm font-semibold text-black transition hover:brightness-110"
                >
                  Go to Uniswap
                </button>
                <p className="mt-2 text-center text-[11px] text-white/55">
                  Connects this account to the pool so beforeSwap reads the live hop score.
                </p>
              </div>
            </div>
          )}
        </div>
      </aside>
    </div>
  );
}

/**
 * Single token row in the MetaMask-style asset list.
 */
function TokenRow({
  symbol,
  name,
  amount,
  usd,
  tone,
  hint,
}: {
  symbol: string;
  name: string;
  amount: string;
  usd: string;
  tone: string;
  hint?: string;
}) {
  return (
    <div className="flex items-center gap-3 rounded-xl px-3 py-3">
      <span
        className="flex h-9 w-9 items-center justify-center rounded-full text-[10px] font-bold text-white"
        style={{ background: tone }}
      >
        {symbol.slice(0, 1)}
      </span>
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-white">{name}</div>
        <div className="text-xs text-white/45">{amount}</div>
      </div>
      <div className="shrink-0 text-right">
        <div className="text-sm font-semibold text-white">{usd}</div>
        {hint && (
          <div className="mt-0.5 max-w-[9.5rem] text-[10px] leading-snug text-white/35">
            {hint}
          </div>
        )}
      </div>
    </div>
  );
}
