"use client";

import type { CSSProperties, ReactNode } from "react";
import type { DemoCase } from "@/data/cases";
import { OnChainAccumulator } from "@/components/OnChainAccumulator";
import { ScrollReveal } from "@/components/ScrollReveal";
import type { HookChainEvent } from "@/lib/hookEvents";

type Props = {
  demoCase: DemoCase;
  connectedAddress: string | null;
  /** Hook audit emits accumulated from afterSwap / beforeSwap */
  chainEvents: HookChainEvent[];
};

/**
 * Truncates a wallet address for compact display in the metadata row.
 */
function shorten(addr: string) {
  if (addr.length < 12) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Audit / compliance report shown after the simulator finishes.
 * Blocks reveal slowly as the user scrolls downward.
 */
export function AuditReport({
  demoCase,
  connectedAddress,
  chainEvents,
}: Props) {
  const address = connectedAddress ?? demoCase.wallet;
  const gaugeTone =
    demoCase.decision === "block" ? "bad" : demoCase.decision === "fee_override" ? "warn" : "ok";
  const gaugeAccent =
    gaugeTone === "ok" ? "#4DB6FF" : gaugeTone === "warn" ? "#F0B90B" : "#FF5370";

  return (
    <section className="relative mx-auto w-full max-w-[1200px] pb-24 pt-8">
      <ScrollReveal>
        <div className="mb-12 px-2 pb-4 pt-8 text-center md:mb-16 md:pt-12">
          <p className="text-sm font-semibold uppercase tracking-[0.22em] text-uni-pink">
            Audit report
          </p>
          <h2 className="mt-4 text-balance text-4xl font-extrabold tracking-tight md:text-5xl">
            AML analysis
          </h2>
          <p className="mx-auto mt-4 max-w-md text-sm text-uni-muted">
            Scroll down — each section fades in as it enters view.
          </p>
        </div>
      </ScrollReveal>

      <ScrollReveal delayMs={80}>
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
      </ScrollReveal>

      <div className="grid gap-4 md:grid-cols-2">
        <ScrollReveal delayMs={120}>
          <div
            className="h-full rounded-[28px] border border-[#1B4F7A]/50 px-12 py-8 shadow-[0_0_40px_rgba(77,182,255,0.08)] md:px-16 md:py-10 lg:px-20"
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
        </ScrollReveal>

        <ScrollReveal delayMs={220}>
          <div
            className="h-full rounded-[28px] border border-[#7A1B5A]/45 px-12 py-8 shadow-[0_0_40px_rgba(252,114,255,0.1)] md:px-16 md:py-10 lg:px-20"
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
                  {demoCase.activity.hopDistance == null
                    ? "—"
                    : demoCase.activity.hopDistance}
                </div>
                <div className="text-sm text-[#F5A3FF]/80">Hop distance</div>
              </div>
              <div>
                <div className="text-3xl font-bold text-uni-pink">
                  {demoCase.exploitConfirmed
                    ? "Exploit"
                    : demoCase.typology.split(" ")[0]}
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
        </ScrollReveal>
      </div>

      <ScrollReveal delayMs={100} className="mt-4">
        <div
          className="rounded-[28px] border border-[#5B4A8A]/45 px-5 py-10 shadow-[0_0_40px_rgba(167,139,250,0.1)] sm:px-8 md:px-10 md:py-14 lg:px-12 lg:py-16"
          style={{
            background:
              "linear-gradient(145deg, #1c1633 0%, #120e22 45%, #0a0814 100%)",
          }}
        >
          <div className="mx-auto w-full max-w-4xl">
            <div className="mb-3 flex items-center justify-center gap-2 text-sm font-medium text-[#C4B5FD]">
              <span aria-hidden>✦</span>
              <span>Compliance Officer Agent · AI</span>
            </div>
            <h3 className="text-center text-2xl font-bold leading-snug text-[#EDE9FE] md:text-3xl">
              {demoCase.agent.status}
            </h3>
            <div className="mt-6 flex w-full flex-wrap justify-center gap-2">
              <span className="rounded-full border border-[#A78BFA]/45 bg-[#A78BFA]/15 px-3.5 py-1.5 text-xs font-semibold text-[#DDD6FE]">
                {demoCase.agent.hookOutput}
              </span>
              <span className="rounded-full border border-[#A78BFA]/30 bg-[#A78BFA]/8 px-3.5 py-1.5 text-xs font-semibold text-[#C4B5FD]">
                {demoCase.agent.documentType}
              </span>
              <span className="rounded-full border border-[#A78BFA]/30 bg-[#A78BFA]/8 px-3.5 py-1.5 text-xs font-semibold text-[#C4B5FD]">
                Confidence {demoCase.agent.confidence}
              </span>
              {demoCase.agent.humanReview && (
                <span className="rounded-full border border-[#A78BFA]/50 bg-[#A78BFA]/15 px-3.5 py-1.5 text-xs font-semibold text-[#EDE9FE]">
                  Human review required
                </span>
              )}
            </div>
          </div>

          <ScrollReveal delayMs={120} className="mx-auto mt-10 max-w-4xl">
            <div className="grid gap-4 sm:grid-cols-3">
              <MetaCell label="Recipient" value={demoCase.agent.recipient} />
              <MetaCell label="Audit hash" value={demoCase.agent.auditHash} mono />
              <MetaCell
                label="Retention"
                value={`${demoCase.agent.retentionYears} years (FATF Rec. 11 · BSA)`}
              />
            </div>
          </ScrollReveal>

          <div className="mx-auto mt-4 max-w-4xl">
            <ScrollReveal delayMs={80}>
              <ReportSection title="A. Technical compliance opinion">
                {demoCase.agent.technicalOpinion.issued ? (
                  <div className="space-y-6">
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
                    <SourcesConsulted
                      sources={demoCase.agent.technicalOpinion.sourcesConsulted}
                      numbered
                    />
                    <OpinionRow
                      label="6. Decision executed"
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
                ) : (
                  <div className="space-y-6">
                    <p className="text-base leading-7 text-[#EDE9FE]/90">
                      A full technical opinion was not required. The score stayed below the
                      REVERT and reasonable-suspicion bands, so the agent issued a short
                      decision record instead — enough for the file, without extra friction.
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
                    <SourcesConsulted
                      sources={demoCase.agent.technicalOpinion.sourcesConsulted}
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
            </ScrollReveal>

            <ScrollReveal delayMs={100}>
              <ReportSection title="B. SAR support annex">
                {demoCase.agent.sarAnnex ? (
                  <div className="space-y-6">
                    <div className="grid gap-4 sm:grid-cols-2">
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
                      label="What happened"
                      value={demoCase.agent.sarAnnex.narrativeDescription}
                    />
                    <OpinionRow
                      label="Why it matters"
                      value={demoCase.agent.sarAnnex.narrativeAnalysis}
                    />
                    <OpinionRow
                      label="Evidence on file"
                      value={demoCase.agent.sarAnnex.narrativeEvidence}
                    />
                    <OpinionRow
                      label="Bottom line"
                      value={demoCase.agent.sarAnnex.narrativeConclusion}
                    />
                    <div>
                      <div className="mb-3 text-sm font-medium text-[#C4B5FD]">
                        Before you file — keep these in mind
                      </div>
                      <ul className="space-y-3 text-base leading-7 text-[#EDE9FE]/90">
                        {demoCase.agent.sarAnnex.warnings.map((w) => (
                          <li key={w} className="flex gap-3">
                            <span className="mt-2.5 h-1.5 w-1.5 shrink-0 rounded-full bg-[#A78BFA]" />
                            <span>{w}</span>
                          </li>
                        ))}
                      </ul>
                    </div>
                  </div>
                ) : (
                  <div className="space-y-6">
                    <p className="text-base leading-7 text-[#EDE9FE]/90">
                      No SAR-support annex was drafted for this wallet. That annex only opens when
                      reasonable suspicion is reached and the operator looks BSA-covered. Here,
                      those gates were not crossed.
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
            </ScrollReveal>

            <ScrollReveal delayMs={100}>
              <ReportSection title="C. Decision record">
                <div className="grid gap-4 sm:grid-cols-2">
                  <MetaCell label="Score" value={demoCase.agent.decisionRecord.score} />
                  <MetaCell label="Output" value={demoCase.agent.decisionRecord.output} />
                  <MetaCell label="Basis code" value={demoCase.agent.decisionRecord.basis} mono />
                  <MetaCell
                    label="Next review"
                    value={demoCase.agent.decisionRecord.nextReview}
                  />
                </div>
                <div className="mt-6">
                  <OpinionRow
                    label="Main facts"
                    value={demoCase.agent.decisionRecord.mainFacts}
                  />
                </div>
              </ReportSection>
            </ScrollReveal>

            <ScrollReveal delayMs={100}>
              <ReportSection title="D. Pool monitoring report (excerpt)">
                <div className="grid gap-4 sm:grid-cols-2">
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
            </ScrollReveal>

            <ScrollReveal delayMs={100}>
              <ReportSection title="E. Authority request compilation">
                <div className="space-y-6">
                  <p className="text-base leading-7 text-[#EDE9FE]/90">
                    If an authority asks for material, the agent only gathers what was requested
                    (file index, audit hash, on-chain events, and source timestamps). It does not
                    draft, sign, or send any response itself.
                  </p>
                  <OpinionRow
                    label="What gets compiled"
                    value="Decision record, optional technical opinion / SAR-support annex (if any), SwapObserved / ScoreUpdated / WalletBlocked events, sanctions oracle receipts, and retention metadata."
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
            </ScrollReveal>

            <ScrollReveal delayMs={80}>
              <p className="mt-10 border-t border-[#A78BFA]/20 pt-8 text-base leading-7 text-[#C4B5FD]/70">
                {demoCase.agent.note}
              </p>
            </ScrollReveal>
          </div>
        </div>
      </ScrollReveal>

      <ScrollReveal delayMs={120} className="mt-4">
        <OnChainAccumulator events={chainEvents} />
      </ScrollReveal>
    </section>
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
    <div className="rounded-2xl border border-[#A78BFA]/25 bg-transparent px-5 py-4">
      <div className="text-xs font-medium text-[#C4B5FD]">{label}</div>
      <div
        className={`mt-2 text-base leading-snug text-[#EDE9FE] ${mono ? "font-mono text-sm" : ""}`}
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
    <div className="mt-8 rounded-2xl border border-[#A78BFA]/20 bg-transparent p-6 md:mt-10 md:p-8">
      <h4 className="mb-5 text-base font-semibold tracking-tight text-[#DDD6FE] md:text-lg">
        {title}
      </h4>
      {children}
    </div>
  );
}

function OpinionRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-[#A78BFA]/10 pb-5 last:border-0 last:pb-0">
      <div className="text-sm font-medium text-[#C4B5FD]">{label}</div>
      <p className="mt-2 text-base leading-7 text-[#EDE9FE]/92">{value}</p>
    </div>
  );
}

function SourcesConsulted({
  sources,
  numbered = false,
}: {
  sources: string[];
  numbered?: boolean;
}) {
  return (
    <div className="border-b border-[#A78BFA]/10 pb-5 last:border-0 last:pb-0">
      <div className="text-sm font-medium text-[#C4B5FD]">
        {numbered ? "5. Sources consulted" : "Sources consulted"}
      </div>
      <p className="mt-2 text-sm leading-6 text-[#C4B5FD]/75">
        The dictamen is grounded only in the sources below — no external filing was made.
      </p>
      <ul className="mt-3 space-y-2.5">
        {sources.map((source) => (
          <li
            key={source}
            className="flex gap-3 text-base leading-7 text-[#EDE9FE]/92"
          >
            <span
              className="mt-2.5 h-1.5 w-1.5 shrink-0 rounded-full bg-[#A78BFA]"
              aria-hidden
            />
            <span>{source}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
