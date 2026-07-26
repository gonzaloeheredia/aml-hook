"use client";

import type { CSSProperties, ReactNode } from "react";
import type { DemoCase } from "@/data/cases";

type Props = {
  demoCase: DemoCase;
  connectedAddress: string | null;
};

/**
 * Truncates a wallet address for compact display in the metadata row.
 */
function shorten(addr: string) {
  if (addr.length < 12) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Audit / compliance report section shown after the user connects a wallet.
 *
 * Layout (4 blocks):
 * 1. Metadata strip (subject, chain, address, audit time)
 * 2. Report Overview — blue Uniswap-style card (score + summary)
 * 3. Detection Data — pink card (structuring signals / tags)
 * 4. Compliance Officer Agent — gray card with regulatory-report products (A–E)
 */
export function AuditReport({ demoCase, connectedAddress }: Props) {
  const address = connectedAddress ?? demoCase.wallet;
  const gaugeTone =
    demoCase.decision === "block" ? "bad" : demoCase.decision === "surcharge" ? "warn" : "ok";
  const gaugeAccent =
    gaugeTone === "ok" ? "#4DB6FF" : gaugeTone === "warn" ? "#F0B90B" : "#FF5370";

  return (
    <section className="relative mx-auto w-full max-w-[1400px] animate-fadeUp pb-24 pt-8">
      <div className="mb-12 px-2 pb-4 pt-8 text-center md:mb-16 md:pt-12">
        <p className="text-sm font-semibold uppercase tracking-[0.22em] text-uni-pink">
          Audit report
        </p>
        <h2 className="mt-4 text-balance text-4xl font-extrabold tracking-tight md:text-5xl">
          AML analysis
        </h2>
      </div>

      {/* Block 1 — subject metadata */}
      <div className="mb-10 grid gap-4 rounded-3xl border border-uni-border bg-uni-card/80 p-5 md:mb-14 md:grid-cols-4 md:p-6">
        <div>
          <div className="text-[11px] uppercase tracking-wider text-uni-muted">Subject</div>
          <div className="mt-1 font-semibold">{demoCase.walletLabel}</div>
        </div>
        <div>
          <div className="text-[11px] uppercase tracking-wider text-uni-muted">Blockchain</div>
          <div className="mt-1 inline-flex rounded-full bg-[#627EEA]/20 px-2.5 py-1 text-xs font-semibold text-[#9BB0FF]">
            Ethereum
          </div>
        </div>
        <div>
          <div className="text-[11px] uppercase tracking-wider text-uni-muted">Address</div>
          <div className="mt-1 font-mono text-sm">{shorten(address)}</div>
        </div>
        <div>
          <div className="text-[11px] uppercase tracking-wider text-uni-muted">Audited</div>
          <div className="mt-1 text-sm">Jul 26, 2026 · demo</div>
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        {/* Block 2 — Report Overview (blue) */}
        <div
          className="rounded-[28px] border border-[#1B4F7A]/50 p-6 shadow-[0_0_40px_rgba(77,182,255,0.08)]"
          style={{
            background:
              "linear-gradient(145deg, #13263d 0%, #0a1522 45%, #050a12 100%)",
          }}
        >
          <div className="mb-4 flex items-center gap-2 text-sm font-medium text-[#4DB6FF]">
            <span aria-hidden>▣</span>
            <span>Report Overview</span>
          </div>

          <div className="flex items-center gap-5">
            <div>
              <div className="text-3xl font-bold text-[#4DB6FF]">{demoCase.riskLabel}</div>
              <div className="mt-1 text-sm text-[#7EC8FF]/80">{demoCase.decisionLabel}</div>
            </div>
            <div
              className="gauge relative flex h-28 w-28 items-center justify-center rounded-full"
              style={
                {
                  "--gauge-color": gaugeAccent,
                  "--gauge-pct": demoCase.score,
                } as CSSProperties
              }
            >
              <div
                className="flex h-[5.5rem] w-[5.5rem] flex-col items-center justify-center rounded-full"
                style={{ background: "#0a1522" }}
              >
                <span className="text-3xl font-bold text-[#4DB6FF]">{demoCase.score}</span>
                <span className="text-[10px] uppercase text-[#7EC8FF]/70">score</span>
              </div>
            </div>
          </div>

          <ul className="mt-5 space-y-3 text-sm text-[#7EC8FF]">
            {demoCase.summary.map((line) => (
              <li key={line} className="flex gap-2">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-[#4DB6FF]" />
                <span>{line}</span>
              </li>
            ))}
          </ul>
        </div>

        {/* Block 3 — Detection Data (pink) */}
        <div
          className="rounded-[28px] border border-[#7A1B5A]/45 p-6 shadow-[0_0_40px_rgba(252,114,255,0.1)]"
          style={{
            background:
              "linear-gradient(145deg, #2a0b21 0%, #1a0714 45%, #12040e 100%)",
          }}
        >
          <div className="mb-4 flex items-center gap-2 text-sm font-medium text-uni-pink">
            <span aria-hidden>◈</span>
            <span>Detection Data</span>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <div className="text-3xl font-bold text-uni-pink">
                {demoCase.structuring.txCount}
              </div>
              <div className="text-sm text-[#F5A3FF]/80">Structuring txs</div>
            </div>
            <div>
              <div className="text-3xl font-bold text-uni-pink">
                {demoCase.sanctioned ? "OFAC" : demoCase.typology.split(" ")[0]}
              </div>
              <div className="text-sm text-[#F5A3FF]/80">Typology</div>
            </div>
          </div>

          <div className="mt-5">
            <div className="mb-2 text-sm text-[#F5A3FF]/70">Top signals</div>
            <div className="flex flex-wrap gap-2">
              {demoCase.tags.map((tag) => (
                <span
                  key={tag.label}
                  className="rounded-full border border-uni-pink/35 bg-uni-pink/10 px-3 py-1 text-xs font-semibold text-uni-pink"
                >
                  {tag.label}
                </span>
              ))}
            </div>
          </div>

          <div className="mt-5 space-y-2">
            {demoCase.signals.map((s) => (
              <div
                key={s.label}
                className="flex items-center justify-between rounded-xl border border-uni-pink/20 bg-black/25 px-3 py-2 text-sm"
              >
                <span className="text-[#F5A3FF]/75">{s.label}</span>
                <span className="font-medium text-uni-pink">{s.value}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Block 4 — Compliance Officer Agent report products */}
      <div className="mt-4 rounded-[28px] border border-white/15 bg-[#2A2A2A] p-8 md:p-10">
        <div className="w-full">
          <div className="mb-2 flex items-center justify-center gap-2 text-sm font-medium text-white/70">
            <span aria-hidden>✦</span>
            <span>Compliance Officer Agent · AI</span>
          </div>
          <h3 className="text-center text-2xl font-bold text-white md:text-3xl">
            {demoCase.agent.status}
          </h3>
          <p className="mt-3 w-full text-sm leading-relaxed text-white/70">
            Regulatory report package for the pool Compliance Officer (
            <span className="text-white">task-regulatory-report</span>). Internal evidence
            only — the agent never files with any authority.
          </p>
          <div className="mt-5 flex w-full flex-wrap gap-2">
            <span className="rounded-full border border-white/25 bg-white/10 px-3 py-1.5 text-xs font-semibold text-white">
              {demoCase.agent.hookOutput}
            </span>
            <span className="rounded-full border border-white/25 bg-white/5 px-3 py-1.5 text-xs font-semibold text-white/90">
              {demoCase.agent.documentType}
            </span>
            <span className="rounded-full border border-white/25 bg-white/5 px-3 py-1.5 text-xs font-semibold text-white/90">
              Confidence {demoCase.agent.confidence}
            </span>
            {demoCase.agent.humanReview && (
              <span className="rounded-full border border-white/40 bg-white/10 px-3 py-1.5 text-xs font-semibold text-white">
                Human review required
              </span>
            )}
          </div>
        </div>

        <div className="mt-8 grid gap-4 sm:grid-cols-3">
          <MetaCell label="Recipient" value={demoCase.agent.recipient} />
          <MetaCell label="Audit hash" value={demoCase.agent.auditHash} mono />
          <MetaCell
            label="Retention"
            value={`${demoCase.agent.retentionYears} years (FATF Rec. 11 · BSA)`}
          />
        </div>

        {/* A. Technical opinion */}
        <ReportSection title="A. Technical compliance opinion">
          {demoCase.agent.technicalOpinion.issued ? (
            <div className="space-y-4">
              <OpinionRow
                label="1. Object & scope"
                value={demoCase.agent.technicalOpinion.objectAndScope}
              />
              <OpinionRow
                label="2. Risk level & scoring"
                value={demoCase.agent.technicalOpinion.riskAndScoring}
              />
              <OpinionRow
                label="3. Typologies identified"
                value={demoCase.agent.technicalOpinion.typologies}
              />
              <OpinionRow
                label="4. Sanctions verification"
                value={demoCase.agent.technicalOpinion.sanctionsCheck}
              />
              <OpinionRow
                label="5. Decision executed"
                value={demoCase.agent.technicalOpinion.decisionExecuted}
              />
              <OpinionRow
                label="6. Legal basis"
                value={demoCase.agent.technicalOpinion.legalBasis}
              />
              <OpinionRow
                label="7. Recommendations"
                value={demoCase.agent.technicalOpinion.recommendations}
              />
              <OpinionRow
                label="8. Traceability"
                value={demoCase.agent.technicalOpinion.traceability}
              />
            </div>
          ) : (
            <p className="text-sm leading-relaxed text-white/75">
              Full technical opinion not required for this event. A short decision record was
              issued instead (score below REVERT / reasonable-suspicion thresholds).
            </p>
          )}
        </ReportSection>

        {/* B. SAR support annex */}
        <ReportSection title="B. SAR support annex">
          {demoCase.agent.sarAnnex ? (
            <div className="space-y-4">
              <div className="grid gap-3 sm:grid-cols-2">
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
                label="Activity description"
                value={demoCase.agent.sarAnnex.narrativeDescription}
              />
              <OpinionRow label="Analysis" value={demoCase.agent.sarAnnex.narrativeAnalysis} />
              <OpinionRow
                label="Supporting evidence"
                value={demoCase.agent.sarAnnex.narrativeEvidence}
              />
              <OpinionRow
                label="Conclusion"
                value={demoCase.agent.sarAnnex.narrativeConclusion}
              />
              <div>
                <div className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-white/50">
                  Filing warnings
                </div>
                <ul className="space-y-2 text-sm text-white/80">
                  {demoCase.agent.sarAnnex.warnings.map((w) => (
                    <li key={w} className="flex gap-2">
                      <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-white/60" />
                      <span>{w}</span>
                    </li>
                  ))}
                </ul>
              </div>
            </div>
          ) : (
            <p className="text-sm leading-relaxed text-white/75">
              Not produced. SAR-support annex is only drafted when reasonable suspicion is
              reached and protocol-obligations indicates the operator is likely BSA-covered.
            </p>
          )}
        </ReportSection>

        {/* C. Decision record */}
        <ReportSection title="C. Decision record">
          <div className="grid gap-3 sm:grid-cols-2">
            <MetaCell label="Score" value={demoCase.agent.decisionRecord.score} />
            <MetaCell label="Output" value={demoCase.agent.decisionRecord.output} />
            <MetaCell label="Basis code" value={demoCase.agent.decisionRecord.basis} mono />
            <MetaCell
              label="Next review"
              value={demoCase.agent.decisionRecord.nextReview}
            />
          </div>
          <div className="mt-4">
            <OpinionRow
              label="Main facts"
              value={demoCase.agent.decisionRecord.mainFacts}
            />
          </div>
        </ReportSection>

        {/* D. Pool aggregate report excerpt */}
        <ReportSection title="D. Pool monitoring report (excerpt)">
          <div className="grid gap-3 sm:grid-cols-2">
            <MetaCell label="Period" value={demoCase.agent.poolReport.period} />
            <MetaCell
              label="Coverage"
              value={demoCase.agent.poolReport.swapsEvaluated}
            />
            <MetaCell
              label="Output distribution"
              value={demoCase.agent.poolReport.outputDistribution}
            />
            <MetaCell
              label="Reasonable suspicion"
              value={demoCase.agent.poolReport.reasonableSuspicionCases}
            />
          </div>
        </ReportSection>

        {/* E. Authority-request rule */}
        <ReportSection title="E. Authority request compilation">
          <p className="text-sm leading-relaxed text-white/80">
            If the operator receives an authority request, the agent only compiles the
            requested material (file index, <span className="text-white">audit_hash</span>,
            on-chain events, sources). It does not draft or send the response. Recipient:
            operator legal / Compliance Officer.
          </p>
        </ReportSection>

        <p className="mt-8 border-t border-white/10 pt-6 text-sm leading-relaxed text-white/60">
          {demoCase.agent.note}
        </p>
      </div>
    </section>
  );
}

/**
 * Small labeled value cell used inside the gray agent report card.
 */
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
    <div className="rounded-2xl border border-white/10 bg-white/5 px-4 py-3.5">
      <div className="text-[11px] font-semibold uppercase tracking-wider text-white/45">
        {label}
      </div>
      <div className={`mt-1.5 text-sm text-white ${mono ? "font-mono" : ""}`}>{value}</div>
    </div>
  );
}

/**
 * Section wrapper with extra padding for each regulatory-report product (A–E).
 */
function ReportSection({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="mt-8 rounded-2xl border border-white/10 bg-[#333333] p-6 md:p-7">
      <h4 className="mb-4 text-sm font-semibold uppercase tracking-[0.14em] text-white">
        {title}
      </h4>
      {children}
    </div>
  );
}

/**
 * Labeled paragraph row inside a technical opinion / SAR narrative.
 */
function OpinionRow({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[11px] font-semibold uppercase tracking-wider text-white/45">
        {label}
      </div>
      <p className="mt-1.5 text-sm leading-relaxed text-white/90">{value}</p>
    </div>
  );
}
