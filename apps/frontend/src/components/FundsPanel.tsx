"use client";

import { useCallback, useEffect, useState } from "react";
import {
  fetchCompensation,
  fetchTreasury,
  postCompensationClaim,
  postCompensationCloseEpoch,
  postDemoElapse,
  postTreasuryCancel,
  postTreasuryExecute,
  postTreasuryPropose,
  type ApiCompensation,
  type ApiTreasury,
} from "@/lib/api";

type Props = {
  apiOnline: boolean;
  tick: number;
};

/**
 * Product close of FeeEscrow: LP claim after a clean epoch, delayed
 * ComplianceTreasury payouts after an illicit recover.
 */
export function FundsPanel({ apiOnline, tick }: Props) {
  const [comp, setComp] = useState<ApiCompensation | null>(null);
  const [treas, setTreas] = useState<ApiTreasury | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [payoutTo, setPayoutTo] = useState("");
  const [payoutAmt, setPayoutAmt] = useState("1");
  const [payoutMemo, setPayoutMemo] = useState("SAR file");

  const reload = useCallback(async () => {
    if (!apiOnline) return;
    try {
      const [c, t] = await Promise.all([fetchCompensation(), fetchTreasury()]);
      setComp(c);
      setTreas(t);
      if (!payoutTo && c.recipients[0]) setPayoutTo(c.recipients[0]);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to read funds");
    }
  }, [apiOnline, payoutTo]);

  useEffect(() => {
    void reload();
  }, [reload, tick]);

  if (!apiOnline) return null;

  return (
    <div className="surface radius-c mx-auto mt-6 w-full max-w-3xl border-t hair px-5 py-5 text-sm md:-translate-x-6">
      <h3 className="font-serif text-lg text-uni-pink">LP compensation &amp; compliance treasury</h3>
      <p className="mt-1 text-xs text-uni-muted">
        Clean RiskFee releases accrue in the LP vault. Close an epoch to publish a merkle root, then
        claim. Illicit recovers book ComplianceTreasury; payouts wait 48h and never go to the vault.
      </p>

      {error && <p className="mt-2 text-uni-bad">{error}</p>}

      <div className="mt-4 grid gap-6 sm:grid-cols-2">
        <section>
          <div className="label-kicker">LP vault</div>
          <p className="mt-1 font-mono text-xs text-uni-muted">
            {comp ? `${comp.balanceUsdc} USDC · epoch ${comp.openEpochId}` : "n/a"}
          </p>
          <div className="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              disabled={busy !== null}
              className="border-b hair px-0.5 pb-0.5 text-xs text-uni-muted"
              onClick={async () => {
                setBusy("close");
                try {
                  const res = await postCompensationCloseEpoch();
                  setComp(res);
                } catch (err) {
                  setError(err instanceof Error ? err.message : "Close epoch failed");
                } finally {
                  setBusy(null);
                }
              }}
            >
              Close epoch
            </button>
          </div>
          <ul className="mt-3 space-y-2">
            {(comp?.epochs ?? [])
              .filter((e) => !e.open)
              .map((epoch) => (
                <li key={epoch.id} className="border-l hair py-2 pl-3 font-mono text-xs">
                  <div className="text-uni-pink">
                    Epoch {epoch.id} · {epoch.potUsdc} USDC
                  </div>
                  {epoch.leaves.map((leaf) => (
                    <div key={leaf.account} className="mt-1 flex items-center justify-between text-uni-muted">
                      <span>
                        {leaf.account.slice(0, 8)}… · {leaf.amountUsdc} USDC
                        {leaf.claimed ? " · claimed" : ""}
                      </span>
                      {!leaf.claimed && (
                        <button
                          type="button"
                          disabled={busy !== null}
                          className="radius-chip bg-uni-warn/20 px-2 py-1 text-uni-warn"
                          onClick={async () => {
                            setBusy(`claim-${epoch.id}`);
                            try {
                              const res = await postCompensationClaim(epoch.id, leaf.account);
                              setComp(res);
                            } catch (err) {
                              setError(err instanceof Error ? err.message : "Claim failed");
                            } finally {
                              setBusy(null);
                            }
                          }}
                        >
                          Claim
                        </button>
                      )}
                    </div>
                  ))}
                </li>
              ))}
          </ul>
        </section>

        <section>
          <div className="label-kicker">Compliance treasury</div>
          <p className="mt-1 font-mono text-xs text-uni-muted">
            {treas
              ? `principal ${treas.lpPrincipalUsdc} · illicit fee ${treas.illicitRiskFeeUsdc} USDC`
              : "n/a"}
          </p>
          <div className="mt-3 space-y-2">
            <input
              className="w-full border-b hair bg-transparent py-1 font-mono text-xs"
              placeholder="Authority destination"
              value={payoutTo}
              onChange={(e) => setPayoutTo(e.target.value)}
            />
            <input
              className="w-full border-b hair bg-transparent py-1 font-mono text-xs"
              placeholder="Amount USDC"
              value={payoutAmt}
              onChange={(e) => setPayoutAmt(e.target.value)}
            />
            <input
              className="w-full border-b hair bg-transparent py-1 text-xs"
              placeholder="File memo"
              value={payoutMemo}
              onChange={(e) => setPayoutMemo(e.target.value)}
            />
            <button
              type="button"
              disabled={busy !== null}
              className="border-b hair px-0.5 pb-0.5 text-xs text-uni-muted"
              onClick={async () => {
                setBusy("propose");
                try {
                  const res = await postTreasuryPropose({
                    account: "ILLICIT_RISK_FEE",
                    amountUsdc: Number(payoutAmt),
                    to: payoutTo,
                    memo: payoutMemo,
                  });
                  setTreas(res);
                } catch (err) {
                  setError(err instanceof Error ? err.message : "Propose failed");
                } finally {
                  setBusy(null);
                }
              }}
            >
              Propose illicit-fee payout
            </button>
            <button
              type="button"
              disabled={busy !== null}
              className="ml-3 border-b hair px-0.5 pb-0.5 text-xs text-uni-muted"
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
          </div>
          <ul className="mt-3 space-y-2">
            {(treas?.payouts ?? []).map((p) => (
              <li key={p.id} className="border-l hair py-2 pl-3 font-mono text-xs">
                <div className="flex justify-between text-uni-pink">
                  <span>
                    #{p.id} · {p.account} · {p.amountUsdc} USDC
                  </span>
                  <span className="text-uni-warn">{p.status}</span>
                </div>
                <div className="mt-1 truncate text-uni-muted">{p.memo || p.to}</div>
                {p.status === "Pending" && (
                  <div className="mt-2 flex gap-2">
                    <button
                      type="button"
                      disabled={busy !== null}
                      className="radius-chip bg-uni-warn/20 px-2 py-1 text-uni-warn"
                      onClick={async () => {
                        setBusy(`ex-${p.id}`);
                        try {
                          const res = await postTreasuryExecute(p.id);
                          setTreas(res);
                        } catch (err) {
                          setError(err instanceof Error ? err.message : "Execute failed");
                        } finally {
                          setBusy(null);
                        }
                      }}
                    >
                      Execute
                    </button>
                    <button
                      type="button"
                      disabled={busy !== null}
                      className="text-xs text-uni-muted underline"
                      onClick={async () => {
                        setBusy(`ca-${p.id}`);
                        try {
                          const res = await postTreasuryCancel(p.id);
                          setTreas(res);
                        } catch (err) {
                          setError(err instanceof Error ? err.message : "Cancel failed");
                        } finally {
                          setBusy(null);
                        }
                      }}
                    >
                      Cancel
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </section>
      </div>
    </div>
  );
}
