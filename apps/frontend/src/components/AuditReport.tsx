"use client";

import type { CSSProperties, ReactNode } from "react";
import type { DemoCase } from "@/data/cases";

type Props = {
  demoCase: DemoCase;
  connectedAddress: string | null;
  /**
   * `stats` — metadata + Report Overview + Detection Data (AML stats module).
   * `opinion` — Compliance Officer legal / technical opinion.
   */
  variant: "stats" | "opinion";
};

/**
 * Truncates a wallet address for compact display in the metadata row.
 */
function shorten(addr: string) {
  if (addr.length < 12) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * AML stats module — subject bar + overview / detection cards.
 * Compact layout so the full module fits one viewport without scrolling.
 */
export function AmlStats({ demoCase, connectedAddress }: Omit<Props, "variant">) {
  const address = connectedAddress ?? demoCase.wallet;
  const gaugeTone =
    demoCase.decision === "block"
      ? "bad"
      : demoCase.decision === "fee_override"
        ? "warn"
        : "ok";
  const gaugeAccent =
    gaugeTone === "ok" ? "#4DB6FF" : gaugeTone === "warn" ? "#F0B90B" : "#FF5370";

  return (
    <section className="relative mx-auto w-full max-w-[1000px] pb-2 pt-0">
      <div className="mb-3 grid gap-2 rounded-2xl border border-uni-border bg-uni-card/80 px-4 py-3 sm:grid-cols-2 md:grid-cols-4 md:px-6">
        <div>
          <div className="text-[10px] uppercase tracking-wider text-uni-muted">
            Subject
          </div>
          <div className="mt-0.5 text-sm font-semibold">{demoCase.walletLabel}</div>
        </div>
        <div>
          <div className="text-[10px] uppercase tracking-wider text-uni-muted">
            Blockchain
          </div>
          <div className="mt-0.5 inline-flex rounded-full bg-[#627EEA]/20 px-2 py-0.5 text-[11px] font-semibold text-[#9BB0FF]">
            Ethereum
          </div>
        </div>
        <div>
          <div className="text-[10px] uppercase tracking-wider text-uni-muted">
            Address
          </div>
          <div className="mt-0.5 font-mono text-xs">{shorten(address)}</div>
        </div>
        <div>
          <div className="text-[10px] uppercase tracking-wider text-uni-muted">
            Audited
          </div>
          <div className="mt-0.5 text-xs">Jul 26, 2026 · demo</div>
        </div>
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <div
          className="h-full rounded-2xl border border-[#1B4F7A]/50 px-5 py-4 shadow-[0_0_40px_rgba(77,182,255,0.08)] md:px-6"
          style={{
            background:
              "linear-gradient(145deg, #13263d 0%, #0a1522 45%, #050a12 100%)",
          }}
        >
          <div className="mb-2 flex items-center gap-2 text-xs font-medium text-[#4DB6FF]">
            <span aria-hidden>▣</span>
            <span>Report Overview</span>
          </div>

          <div className="flex items-center gap-4">
            <div className="min-w-0 flex-1">
              <div className="text-xl font-bold leading-tight text-[#4DB6FF]">
                {demoCase.riskLabel}
              </div>
              <div className="mt-0.5 text-xs text-[#7EC8FF]/80">
                {demoCase.decisionLabel}
              </div>
            </div>
            <div
              className="gauge relative flex h-20 w-20 shrink-0 items-center justify-center rounded-full"
              style={
                {
                  "--gauge-color": gaugeAccent,
                  "--gauge-pct": demoCase.score,
                } as CSSProperties
              }
            >
              <div
                className="flex h-16 w-16 flex-col items-center justify-center rounded-full"
                style={{ background: "#0a1522" }}
              >
                <span className="text-2xl font-bold text-[#4DB6FF]">
                  {demoCase.score}
                </span>
                <span className="text-[9px] uppercase text-[#7EC8FF]/70">
                  score
                </span>
              </div>
            </div>
          </div>

          <ul className="mt-3 space-y-1.5 text-xs leading-snug text-[#7EC8FF]">
            {demoCase.summary.map((line) => (
              <li key={line} className="flex gap-2">
                <span className="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-[#4DB6FF]" />
                <span>{line}</span>
              </li>
            ))}
          </ul>
        </div>

        <div
          className="h-full rounded-2xl border border-[#7A1B5A]/45 px-5 py-4 shadow-[0_0_40px_rgba(252,114,255,0.1)] md:px-6"
          style={{
            background:
              "linear-gradient(145deg, #2a0b21 0%, #1a0714 45%, #12040e 100%)",
          }}
        >
          <div className="mb-2 flex items-center gap-2 text-xs font-medium text-uni-pink">
            <span aria-hidden>◈</span>
            <span>Detection Data</span>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <div className="text-2xl font-bold text-uni-pink">
                {demoCase.activity.hopDistance == null
                  ? "—"
                  : demoCase.activity.hopDistance}
              </div>
              <div className="text-xs text-[#F5A3FF]/80">Hop distance</div>
            </div>
            <div>
              <div className="text-2xl font-bold text-uni-pink">
                {demoCase.exploitConfirmed
                  ? "Exploit"
                  : demoCase.typology.split(" ")[0]}
              </div>
              <div className="text-xs text-[#F5A3FF]/80">Typology</div>
            </div>
          </div>

          <div className="mt-3">
            <div className="mb-1.5 text-xs text-[#F5A3FF]/70">Top signals</div>
            <div className="flex flex-wrap gap-1.5">
              {demoCase.tags.map((tag) => (
                <span
                  key={tag.label}
                  className="rounded-full border border-uni-pink/35 bg-uni-pink/10 px-2 py-0.5 text-[10px] font-semibold text-uni-pink"
                >
                  {tag.label}
                </span>
              ))}
            </div>
          </div>

          <div className="mt-3 space-y-1.5">
            {demoCase.signals.map((s) => (
              <div
                key={s.label}
                className="flex items-center justify-between rounded-lg border border-uni-pink/20 bg-black/25 px-2.5 py-1.5 text-xs"
              >
                <span className="text-[#F5A3FF]/75">{s.label}</span>
                <span className="font-medium text-uni-pink">{s.value}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

/**
 * Opinion module — Compliance Officer Agent legal / technical opinion.
 * Neutral dark palette aligned with the AML stats subject bar.
 */
export function LegalOpinion({ demoCase }: Pick<Props, "demoCase">) {
  return (
    <section className="relative mx-auto w-full max-w-[1000px] pb-2 pt-0">
      <div className="rounded-2xl border border-uni-border bg-uni-card/80 px-4 py-5 sm:px-6 md:px-8 md:py-6">
        <div className="mx-auto max-w-3xl rounded-xl border border-uni-border/80 px-4 py-3 md:px-5 md:py-4">
          <div className="grid gap-2 sm:grid-cols-3">
            <MetaCell label="Recipient" value={demoCase.agent.recipient} />
            <MetaCell label="Audit hash" value={demoCase.agent.auditHash} mono />
            <MetaCell
              label="Retention"
              value={`${demoCase.agent.retentionYears} years (FATF Rec. 11 · BSA)`}
            />
          </div>
          {demoCase.agent.run ? (
            <div className="mt-2 grid gap-2 sm:grid-cols-3">
              <MetaCell
                label="COA run"
                value={`${demoCase.agent.run.runId} · ${demoCase.agent.run.durationMs}ms`}
                mono
              />
              <MetaCell
                label="Skills"
                value={`${demoCase.agent.run.skillsExecuted.length} · ${demoCase.agent.run.flow}`}
              />
              <MetaCell
                label="Keeper tx"
                value={demoCase.agent.run.publishTxHash ?? "—"}
                mono
              />
            </div>
          ) : null}
        </div>

        <div className="mx-auto mt-2 max-w-3xl">
          <ReportSection
            title={
              demoCase.decision === "allow"
                ? "A. Legal opinion · SAR narrative model"
                : "A. Technical opinion · SAR narrative model"
            }
          >
            <div className="space-y-3">
              <OpinionRow
                label="1. Who — subject(s)"
                value={demoCase.agent.technicalOpinion.objectAndScope}
              />
              <OpinionRow
                label="2. What — instruments & patterns"
                value={demoCase.agent.technicalOpinion.typologies}
              />
              <OpinionRow
                label="3. When — timing"
                value={demoCase.agent.technicalOpinion.sanctionsCheck}
              />
              <OpinionRow
                label="4. Where — venue & addresses"
                value={demoCase.agent.technicalOpinion.sourcesConsulted.join(" · ")}
              />
              <OpinionRow
                label="5. Why — why unusual / elevated"
                value={demoCase.agent.technicalOpinion.riskAndScoring}
              />
              <OpinionRow
                label="6. How — method of operation & control"
                value={demoCase.agent.technicalOpinion.decisionExecuted}
              />
              <OpinionRow
                label="7. Legal basis"
                value={demoCase.agent.technicalOpinion.legalBasis}
              />
              <OpinionRow
                label="8. Recommendations"
                value={demoCase.agent.technicalOpinion.recommendations}
              />
              <OpinionRow
                label="9. Traceability"
                value={demoCase.agent.technicalOpinion.traceability}
              />
            </div>
          </ReportSection>

          <ReportSection title="B. SAR support annex">
            {demoCase.agent.sarAnnex ? (
              <div className="space-y-3">
                <div className="grid gap-2 sm:grid-cols-2">
                  <MetaCell label="Status" value={demoCase.agent.sarAnnex.status} />
                  <MetaCell
                    label="Operation state"
                    value={demoCase.agent.sarAnnex.operationState}
                  />
                  <MetaCell
                    label="Activity period"
                    value={demoCase.agent.sarAnnex.activityPeriod}
                  />
                  <MetaCell
                    label="Amount involved"
                    value={demoCase.agent.sarAnnex.amountInvolved}
                  />
                </div>
                <OpinionRow
                  label="Who / What"
                  value={demoCase.agent.sarAnnex.narrativeDescription}
                />
                <OpinionRow
                  label="When / Where"
                  value={demoCase.agent.sarAnnex.narrativeAnalysis}
                />
                <OpinionRow
                  label="Why"
                  value={demoCase.agent.sarAnnex.narrativeEvidence}
                />
                <OpinionRow
                  label="How · closing"
                  value={demoCase.agent.sarAnnex.narrativeConclusion}
                />
                <div>
                  <div className="mb-2 text-[11px] font-medium text-uni-muted">
                    Before you file — keep these in mind
                  </div>
                  <ul className="space-y-1.5 text-xs leading-relaxed text-white/90">
                    {demoCase.agent.sarAnnex.warnings.map((w) => (
                      <li key={w} className="flex gap-2">
                        <span className="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-white/40" />
                        <span>{w}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              </div>
            ) : (
              <div className="space-y-3">
                <p className="text-xs leading-relaxed text-white/85">
                  No SAR-support annex was drafted for this wallet. That annex
                  only opens when reasonable suspicion is reached and the
                  operator looks BSA-covered. Here, those gates were not
                  crossed.
                </p>
                <OpinionRow
                  label="Drafting gate"
                  value="Reasonable suspicion = false. BSA-covered likelihood not triggered. No annex file opened."
                />
                <OpinionRow
                  label="What to watch next"
                  value="Keep ordinary SwapObserved logging. Re-open the annex workflow if an N-hop score moves into FEE_OVERRIDE or REVERT."
                />
              </div>
            )}
          </ReportSection>

          <ReportSection
            title={
              demoCase.decision === "allow"
                ? "C. Legal opinion record"
                : "C. Decision record"
            }
          >
            <div className="grid gap-2 sm:grid-cols-2">
              <MetaCell label="Score" value={demoCase.agent.decisionRecord.score} />
              <MetaCell label="Output" value={demoCase.agent.decisionRecord.output} />
              <MetaCell
                label="Basis code"
                value={demoCase.agent.decisionRecord.basis}
                mono
              />
              <MetaCell
                label="Next review"
                value={demoCase.agent.decisionRecord.nextReview}
              />
            </div>
            <div className="mt-3">
              <OpinionRow
                label="Main facts"
                value={demoCase.agent.decisionRecord.mainFacts}
              />
            </div>
          </ReportSection>

          <ReportSection title="D. Authority request compilation">
            <div className="space-y-3">
              <p className="text-xs leading-relaxed text-white/85">
                If an authority asks for material, the agent only gathers what
                was requested (file index, audit hash, on-chain events, and
                source timestamps). It does not draft, sign, or send any
                response itself.
              </p>
              <OpinionRow
                label="What gets compiled"
                value="Legal / technical opinion, optional SAR-support annex (if any), SwapObserved / ScoreUpdated / WalletBlocked events, sanctions oracle receipts, and retention metadata."
              />
              <OpinionRow
                label="Who receives it"
                value="Operator legal counsel or the pool Compliance Officer — never FinCEN, OFAC, or other authorities directly."
              />
              <OpinionRow
                label="Hard limits"
                value="No tip-off to the subject. No autonomous filing. No changes to on-chain evidence. A human must own the outbound package."
              />
            </div>
          </ReportSection>

          <p className="mt-4 border-t border-uni-border pt-3 text-xs leading-relaxed text-uni-muted">
            {demoCase.agent.note}
          </p>
        </div>
      </div>
    </section>
  );
}

/** @deprecated Prefer AmlStats / LegalOpinion — kept as thin router. */
export function AuditReport({
  demoCase,
  connectedAddress,
  variant = "stats",
}: Props & { variant?: "stats" | "opinion" }) {
  if (variant === "opinion") {
    return <LegalOpinion demoCase={demoCase} />;
  }
  return (
    <AmlStats demoCase={demoCase} connectedAddress={connectedAddress} />
  );
}

function MetaCell({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="px-1 py-1.5">
      <div className="text-[10px] font-medium uppercase tracking-wider text-uni-muted">
        {label}
      </div>
      <div
        className={`mt-1 text-xs font-semibold leading-snug text-white ${mono ? "font-mono text-[11px] font-medium" : ""}`}
      >
        {value}
      </div>
    </div>
  );
}

function ReportSection({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="mt-3 rounded-xl border border-uni-border bg-uni-card/60 p-3 md:mt-4 md:p-4">
      <h4 className="mb-2.5 text-sm font-semibold tracking-tight text-white">
        {title}
      </h4>
      {children}
    </div>
  );
}

function OpinionRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-uni-border/70 pb-2.5 last:border-0 last:pb-0">
      <div className="text-[11px] font-medium text-uni-muted">{label}</div>
      <p className="mt-1 text-xs leading-relaxed text-white/90">{value}</p>
    </div>
  );
}
