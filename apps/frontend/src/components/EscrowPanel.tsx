"use client";

import { useCallback, useEffect, useState } from "react";
import {
  fetchEscrow,
  postDemoElapse,
  postEscrowCheckpoint2,
  postEscrowRecover,
  type ApiEscrowRow,
} from "@/lib/api";

type Props = {
  apiOnline: boolean;
  tick: number;
};

/**
 * Step 12: live FeeEscrow rows from Anvil. Checkpoint 2 reads the oracle/list,
 * then recover books ComplianceTreasury ILLICIT_RISK_FEE.
 */
export function EscrowPanel({ apiOnline, tick }: Props) {
  const [rows, setRows] = useState<ApiEscrowRow[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!apiOnline) return;
    try {
      const res = await fetchEscrow();
      setRows(res.rows);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to read FeeEscrow");
    }
  }, [apiOnline]);

  useEffect(() => {
    void reload();
  }, [reload, tick]);

  if (!apiOnline) {
    return (
      <div className="surface radius-c mx-auto mt-8 w-full max-w-3xl border-t hair px-5 py-5 text-sm text-uni-muted md:-translate-x-6">
        FeeEscrow is on Anvil. Start the API after <code>npm run deploy:local</code>.
      </div>
    );
  }

  return (
    <div className="surface radius-c mx-auto mt-8 w-full max-w-3xl border-t hair px-5 py-5 text-sm md:-translate-x-6">
      <div className="flex items-center justify-between">
        <h3 className="font-serif text-lg text-uni-pink">FeeEscrow</h3>
        <button type="button" className="text-xs text-uni-muted underline" onClick={() => void reload()}>
          Refresh
        </button>
      </div>
      <p className="mt-1 text-xs text-uni-muted">
        Extra slice only. Warp 48h before Checkpoint 2, then 7d before recover. Checkpoint 2 reads the list and the oracle (score ≥ 71). Recover books ComplianceTreasury ILLICIT_RISK_FEE — never the LP fund.
      </p>
      <div className="mt-2 flex gap-2">
        <button
          type="button"
          className="border-b hair px-0.5 pb-0.5 text-xs text-uni-muted"
          onClick={async () => {
            setBusy("warp48");
            try {
              await postDemoElapse(48 * 3600);
              await reload();
            } catch (err) {
              setError(err instanceof Error ? err.message : "Warp failed");
            } finally {
              setBusy(null);
            }
          }}
        >
          Warp 48h
        </button>
        <button
          type="button"
          className="border-b hair px-0.5 pb-0.5 text-xs text-uni-muted"
          onClick={async () => {
            setBusy("warp7d");
            try {
              await postDemoElapse(7 * 24 * 3600);
              await reload();
            } catch (err) {
              setError(err instanceof Error ? err.message : "Warp failed");
            } finally {
              setBusy(null);
            }
          }}
        >
          Warp 7d
        </button>
      </div>
      {error && <p className="mt-2 text-uni-bad">{error}</p>}
      {rows.length === 0 ? (
        <p className="mt-3 text-uni-muted">No rows yet. A FEE_OVERRIDE swap deposits one.</p>
      ) : (
        <ul className="mt-3 space-y-2">
          {rows.map((row) => (
            <li
              key={row.id}
              className="border-l hair bg-transparent py-2 pl-3 font-mono text-xs"
            >
              <div className="flex justify-between text-uni-pink">
                <span>
                  #{row.id} · {row.walletId ?? row.wallet.slice(0, 8)} · {row.amountUsdc} USDC
                </span>
                <span className="text-uni-warn">{row.status}</span>
              </div>
              <div className="mt-1 truncate text-uni-muted">{row.swapFingerprint}</div>
              <div className="mt-2 flex gap-2">
                {row.status === "Active" && (
                  <button
                    type="button"
                    disabled={busy !== null}
                    className="radius-chip bg-uni-warn/20 px-2 py-1 text-uni-warn"
                    onClick={async () => {
                      setBusy(`c2-${row.id}`);
                      try {
                        const res = await postEscrowCheckpoint2(row.id, true);
                        setRows(res.rows);
                      } catch (err) {
                        setError(err instanceof Error ? err.message : "Checkpoint failed");
                      } finally {
                        setBusy(null);
                      }
                    }}
                  >
                    Checkpoint 2
                  </button>
                )}
                {row.status === "Blocked" && (
                  <button
                    type="button"
                    disabled={busy !== null}
                    className="radius-chip bg-uni-bad/20 px-2 py-1 text-uni-bad"
                    onClick={async () => {
                      setBusy(`r-${row.id}`);
                      try {
                        const res = await postEscrowRecover(row.id);
                        setRows(res.rows);
                      } catch (err) {
                        setError(err instanceof Error ? err.message : "Recover failed");
                      } finally {
                        setBusy(null);
                      }
                    }}
                  >
                    Recover → treasury
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
