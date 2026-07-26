"use client";

import type { CSSProperties, ReactNode } from "react";
import type { DemoCase } from "@/data/cases";
import { OnChainAccumulator } from "@/components/OnChainAccumulator";

type Props = {
  demoCase: DemoCase;
  connectedAddress: string | null;
  /** Baseline score before live volume escalation */
  baseScore: number;
  /** Completed demo swaps for this wallet */
  swapCount: number;
  /** Cumulative USD traded in the 24h demo window */
  tradedUsd: number;
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
 * Layout (5 blocks):
 * 1. Metadata strip (subject, chain, address, audit time)
 * 2. Report Overview — blue Uniswap-style card (score + summary)
 * 3. Detection Data — pink card (structuring signals / tags)
 * 4. Compliance Officer Agent — violet card with regulatory-report products (A–E)
 * 5. On-chain accumulator — pink card (24h volume + ScoreUpdated event)
 */
export function AuditReport({
  demoCase,
  connectedAddress,
  baseScore,
  swapCount,
  tradedUsd,
}: Props) {
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
      <div className="mb-10 grid gap-4 rounded-3xl border border-uni-border bg-uni-card/80 px-12 py-6 md:mb-14 md:grid-cols-4 md:px-20 md:py-8 lg:px-28">
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
          className="rounded-[28px] border border-[#1B4F7A]/50 px-12 py-8 shadow-[0_0_40px_rgba(77,182,255,0.08)] md:px-16 md:py-10 lg:px-20"
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
          className="rounded-[28px] border border-[#7A1B5A]/45 px-12 py-8 shadow-[0_0_40px_rgba(252,114,255,0.1)] md:px-16 md:py-10 lg:px-20"
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

      {/* Block 4 — Compliance Officer Agent (violet bridge between blue + pink) */}
      <div
        className="mt-4 rounded-[28px] border border-[#5B4A8A]/45 px-12 py-10 shadow-[0_0_40px_rgba(167,139,250,0.1)] md:px-20 md:py-14 lg:px-28 lg:py-16"
        style={{
          background:
            "linear-gradient(145deg, #1c1633 0%, #120e22 45%, #0a0814 100%)",
        }}
      >
        <div className="w-full">
          <div className="mb-2 flex items-center justify-center gap-2 text-sm font-medium text-[#C4B5FD]">
            <span aria-hidden>✦</span>
            <span>Compliance Officer Agent · AI</span>
          </div>
          <h3 className="text-center text-2xl font-bold text-[#EDE9FE] md:text-3xl">
            {demoCase.agent.status}
          </h3>
          <p className="mt-3 w-full text-sm leading-relaxed text-[#C4B5FD]/80">
            Regulatory report package for the pool Compliance Officer (
            <span className="text-[#EDE9FE]">task-regulatory-report</span>). Internal evidence
            only — the agent never files with any authority.
          </p>
          <div className="mt-5 flex w-full flex-wrap gap-2">
            <span className="rounded-full border border-[#A78BFA]/45 bg-[#A78BFA]/15 px-3 py-1.5 text-xs font-semibold text-[#DDD6FE]">
              {demoCase.agent.hookOutput}
            </span>
            <span className="rounded-full border border-[#A78BFA]/30 bg-[#A78BFA]/8 px-3 py-1.5 text-xs font-semibold text-[#C4B5FD]">
              {demoCase.agent.documentType}
            </span>
            <span className="rounded-full border border-[#A78BFA]/30 bg-[#A78BFA]/8 px-3 py-1.5 text-xs font-semibold text-[#C4B5FD]">
              Confidence {demoCase.agent.confidence}
            </span>
            {demoCase.agent.humanReview && (
              <span className="rounded-full border border-[#A78BFA]/50 bg-[#A78BFA]/15 px-3 py-1.5 text-xs font-semibold text-[#EDE9FE]">
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
            <div className="space-y-4">
              <p className="text-sm leading-relaxed text-[#EDE9FE]/85">
                Full technical opinion not required for this event. A short decision record was
                issued instead because the score remains below REVERT and reasonable-suspicion
                thresholds under the pool’s permissive policy.
              </p>
              <OpinionRow
                label="Scope note"
                value={demoCase.agent.technicalOpinion.objectAndScope}
              />
              <OpinionRow
                label="Risk level & scoring"
                value={demoCase.agent.technicalOpinion.riskAndScoring}
              />
              <OpinionRow
                label="Typologies"
                value={demoCase.agent.technicalOpinion.typologies}
              />
              <OpinionRow
                label="Sanctions verification"
                value={demoCase.agent.technicalOpinion.sanctionsCheck}
              />
              <OpinionRow
                label="Decision executed"
                value={demoCase.agent.technicalOpinion.decisionExecuted}
              />
              <OpinionRow
                label="Legal basis"
                value={demoCase.agent.technicalOpinion.legalBasis}
              />
              <OpinionRow
                label="Recommendations"
                value={demoCase.agent.technicalOpinion.recommendations}
              />
              <OpinionRow
                label="Traceability"
                value={demoCase.agent.technicalOpinion.traceability}
              />
            </div>
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
                <div className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-[#A78BFA]">
                  Filing warnings
                </div>
                <ul className="space-y-2 text-sm text-[#EDE9FE]/85">
                  {demoCase.agent.sarAnnex.warnings.map((w) => (
                    <li key={w} className="flex gap-2">
                      <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-[#A78BFA]" />
                      <span>{w}</span>
                    </li>
                  ))}
                </ul>
              </div>
            </div>
          ) : (
            <div className="space-y-4">
              <p className="text-sm leading-relaxed text-[#EDE9FE]/85">
                Not produced for this wallet. The SAR-support annex is only drafted when
                reasonable suspicion is reached and protocol-obligations indicates the operator
                is likely BSA-covered. No behavioral red flags crossed the drafting gate on this
                evaluation.
              </p>
              <OpinionRow
                label="Drafting gate"
                value="Reasonable suspicion = false · BSA-covered likelihood not triggered · no annex file opened."
              />
              <OpinionRow
                label="Monitoring stance"
                value="Continue ordinary SwapObserved logging. Re-open annex workflow if 24h volume or structuring counter enters the FEE_DIFERENCIAL / REVERT bands."
              />
            </div>
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
          <div className="space-y-4">
            <p className="text-sm leading-relaxed text-[#EDE9FE]/85">
              If the operator receives an authority request, the agent only compiles the
              requested material (file index,{" "}
              <span className="text-[#C4B5FD]">audit_hash</span>, on-chain events, and
              source timestamps). It does not draft, sign, or send the response to any
              authority.
            </p>
            <OpinionRow
              label="Compilation scope"
              value="Decision record, optional technical opinion / SAR-support annex (if any), SwapObserved / ScoreUpdated / WalletBlocked event list, sanctions oracle query receipts, and retention metadata."
            />
            <OpinionRow
              label="Recipient"
              value="Operator legal counsel / pool Compliance Officer — never FinCEN, OFAC, or other authorities directly."
            />
            <OpinionRow
              label="Hard limits"
              value="No tip-off to the evaluated subject. No autonomous filing. No alteration of on-chain evidence. Human custody of the outbound package remains mandatory."
            />
          </div>
        </ReportSection>

        <p className="mt-8 border-t border-[#A78BFA]/20 pt-6 text-sm leading-relaxed text-[#C4B5FD]/65">
          {demoCase.agent.note}
        </p>
      </div>

      {/* Block 5 — On-chain accumulator / score event (after Compliance Officer Agent) */}
      <OnChainAccumulator
        demoCase={demoCase}
        baseScore={baseScore}
        connectedAddress={connectedAddress}
        swapCount={swapCount}
        tradedUsd={tradedUsd}
      />
    </section>
  );
}

/**
 * Small labeled value cell used inside the violet agent report card.
 * Transparent fill — only a soft violet border so it never reads as a white card.
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
    <div className="rounded-2xl border border-[#A78BFA]/25 bg-transparent px-5 py-4">
      <div className="text-[11px] font-semibold uppercase tracking-wider text-[#A78BFA]">
        {label}
      </div>
      <div className={`mt-1.5 text-sm text-[#EDE9FE] ${mono ? "font-mono" : ""}`}>{value}</div>
    </div>
  );
}

/**
 * Section wrapper with extra padding for each regulatory-report product (A–E).
 * Title uses the same violet as MetaCell labels (RECIPIENT / AUDIT HASH).
 */
function ReportSection({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="mt-10 rounded-2xl border border-[#A78BFA]/25 bg-transparent p-7 md:p-9">
      <h4 className="mb-5 text-sm font-semibold uppercase tracking-[0.14em] text-[#A78BFA]">
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
      <div className="text-[11px] font-semibold uppercase tracking-wider text-[#A78BFA]">
        {label}
      </div>
      <p className="mt-1.5 text-sm leading-relaxed text-[#EDE9FE]/90">{value}</p>
    </div>
  );
}
