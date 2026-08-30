"use client";

import type { CSSProperties } from "react";
import type { Decision, DemoCase } from "@/data/cases";

type Props = {
  demoCase: DemoCase;
  connectedAddress: string | null;
  /**
   * `stats`: metadata + Report Overview + Detection Data (AML stats module).
   * `opinion`: Compliance Officer legal / technical opinion.
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

function opinionChrome(decision: Decision) {
  const accent =
    decision === "block"
      ? "#FF5370"
      : decision === "fee_override"
        ? "#F0B90B"
        : "#4DB6FF";

  return {
    accent,
    verdictBg: "transparent",
    verdictBorder: "rgba(232, 228, 217, 0.16)",
    markBg: "rgb(var(--ink))",
    markFg: "rgb(var(--background))",
  };
}

/** Two-letter mark from the wallet label, used instead of a generic avatar. */
function walletInitials(addr: string, fallback: string) {
  const fromLabel = fallback.replace(/[^A-Za-z]/g, "").slice(0, 2);
  if (fromLabel.length === 2) return fromLabel.toUpperCase();
  if (addr.startsWith("0x") && addr.length >= 4) {
    return addr.slice(2, 4).toUpperCase();
  }
  return "W";
}

/**
 * AML stats module: subject bar + overview / detection cards.
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
    <section className="relative mx-auto w-full max-w-[1000px] pb-2 pt-0 md:translate-x-4">
      <div className="mb-8 grid gap-8 sm:grid-cols-2 md:grid-cols-4">
        <div>
          <div className="label-kicker">Subject</div>
          <div className="mt-2 font-serif text-[22px] leading-tight">{demoCase.walletLabel}</div>
        </div>
        <div>
          <div className="label-kicker">Blockchain</div>
          <div className="mt-2 font-serif text-[22px] leading-tight text-[#9BB0FF]">
            Ethereum
          </div>
        </div>
        <div>
          <div className="label-kicker">Address</div>
          <div className="mt-2 font-mono text-[13px]">{shorten(address)}</div>
        </div>
        <div>
          <div className="label-kicker">Audited</div>
          <div className="mt-2 text-[15px]">Jul 26, 2026 · demo</div>
        </div>
      </div>

      <div className="grid items-start gap-10 md:grid-cols-2">
        <div className="surface radius-f h-full border-l hair px-5 py-6 md:px-6">
          <div className="label-kicker mb-4">Report Overview</div>

          <div className="flex items-end gap-5">
            <div className="min-w-0 flex-1">
              <div className="font-serif text-[28px] leading-tight tracking-tight text-uni-pink">
                {demoCase.riskLabel}
              </div>
              <div className="mt-1 text-[12px] tracking-wide text-uni-muted">
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
                className="flex h-16 w-16 flex-col items-center justify-center rounded-full bg-uni-bg"
              >
                <span className="font-serif text-2xl text-uni-pink">
                  {demoCase.score}
                </span>
                <span className="label-kicker text-[9px]">
                  score
                </span>
              </div>
            </div>
          </div>

          <ul className="mt-6 space-y-2 text-sm leading-relaxed text-uni-muted">
            {demoCase.summary.map((line) => (
              <li key={line} className="flex gap-2">
                <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-uni-pink/60" />
                <span>{line}</span>
              </li>
            ))}
          </ul>
        </div>

        <div className="h-full px-1 py-1 md:pl-2">
          <div className="label-kicker mb-5">Detection Data</div>

          <div className="grid grid-cols-2 gap-6">
            <div>
              <div className="value-hero text-[40px] text-uni-pink md:text-[48px]">
                {demoCase.activity.hopDistance == null
                  ? "n/a"
                  : demoCase.activity.hopDistance}
              </div>
              <div className="label-kicker mt-2">Hop distance</div>
            </div>
            <div>
              <div className="font-serif text-[28px] leading-none tracking-tight text-uni-pink">
                {demoCase.exploitConfirmed
                  ? "Exploit"
                  : demoCase.typology.split(" ")[0]}
              </div>
              <div className="label-kicker mt-2">Typology</div>
            </div>
          </div>

          <div className="mt-8">
            <div className="label-kicker mb-3">Top signals</div>
            <div className="flex flex-wrap gap-x-4 gap-y-2">
              {demoCase.tags.map((tag) => (
                <span
                  key={tag.label}
                  className="border-b hair pb-0.5 text-[11px] font-medium tracking-wide text-uni-pink"
                >
                  {tag.label}
                </span>
              ))}
            </div>
          </div>

          <div className="mt-6 space-y-4">
            {demoCase.signals.map((s) => (
              <div
                key={s.label}
              >
                <span className="label-kicker">{s.label}</span>
                <div className="mt-1 font-serif text-[18px] text-uni-pink">{s.value}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

const LEGAL_PREFIXES = [
  /^Subject:\s*/i,
  /^Role:\s*/i,
  /^Instrument \/ mechanism:\s*/i,
  /^Instrument:\s*/i,
  /^Observed pattern:\s*/i,
  /^Pattern:\s*/i,
  /^Hook instruments:\s*/i,
  /^Hook:\s*/i,
  /^Venue:\s*/i,
  /^Account \/ address under review:\s*/i,
  /^Account under review:\s*/i,
  /^Why not treated as suspicious for enhanced action:\s*/i,
  /^Why elevated:\s*/i,
  /^How \/ control:\s*/i,
  /^WHO:\s*/i,
  /^WHAT:\s*/i,
  /^WHEN:\s*/i,
  /^WHERE:\s*/i,
  /^WHY:\s*/i,
  /^HOW:\s*/i,
];

/**
 * Strips SAR-style labels so the same facts read as plain sentences.
 */
function softenNarrative(text: string): string {
  return text
    .split(". ")
    .map((sentence) => {
      let next = sentence.trim();
      for (const prefix of LEGAL_PREFIXES) {
        next = next.replace(prefix, "");
      }
      if (!next) return "";
      return next.charAt(0).toUpperCase() + next.slice(1);
    })
    .filter(Boolean)
    .join(" ");
}

/**
 * Formal closing opinion for the operator record: not a SAR and not a filing.
 */
function formalLegalOpinion(demoCase: DemoCase): {
  title: string;
  finding: string;
  nature: string;
  directions: string;
  basis: string;
  traceability: string;
} {
  const wallet = demoCase.walletLabel;
  const score = demoCase.score;
  const feePct = (demoCase.appliedFeeBps / 100).toFixed(2);
  const opinion = demoCase.agent.technicalOpinion;
  const facts = demoCase.agent.decisionRecord.mainFacts;

  if (demoCase.decision === "block") {
    return {
      title: "Legal opinion",
      finding: `On the facts evaluated in this session, this office finds that ${wallet} presents REVERT-band exposure (score ${score}/100; band 71–100). Controlling facts: ${facts} Pool policy is fail-closed. The attempted swap shall not settle. WalletBlocked is the controlling on-chain record. Off-pool movement of USDC remains possible and shall continue to be monitored.`,
      nature:
        "This instrument is an internal legal and technical opinion issued to the pool operator. It is not a Suspicious Activity Report, is not filed with FinCEN or any other authority, and shall not be treated as a response to a governmental request. The agent does not tip off the subject.",
      directions: opinion.recommendations,
      basis: opinion.legalBasis,
      traceability: opinion.traceability,
    };
  }

  if (demoCase.decision === "fee_override") {
    return {
      title: "Legal opinion",
      finding: `On the facts evaluated in this session, this office finds that ${wallet} presents elevated, non-blocking risk (score ${score}/100; FEE_OVERRIDE band 31–70). Controlling facts: ${facts} The swap may settle. The pool retains the standard 0.30 percent fee; the risk differential is segregated to FeeEscrow. Total friction on this swap is approximately ${feePct} percent. This finding is a risk-based control. It is not a determination of guilt.`,
      nature:
        "This instrument is an internal legal and technical opinion issued to the pool operator, together with a SAR-support annex where indicated. The annex is a support draft only. It is not a FinCEN SAR and must not be filed by the agent.",
      directions: opinion.recommendations,
      basis: opinion.legalBasis,
      traceability: opinion.traceability,
    };
  }

  return {
    title: "Legal opinion",
    finding: `On the facts evaluated in this session, this office finds that ${wallet} does not present reasonable suspicion for enhanced action (score ${score}/100; ALLOW band 0–30). Controlling facts: ${facts} The simulated Layer-1 sanctions screen is clear. The subject may transact at the standard pool fee of 0.30 percent.`,
    nature:
      "This instrument is an internal legal opinion issued to the pool operator. It is not a Suspicious Activity Report, is not filed with FinCEN or any other authority, and shall not be treated as a response to a governmental request.",
    directions: opinion.recommendations,
    basis: opinion.legalBasis,
    traceability: opinion.traceability,
  };
}

function verdictCopy(demoCase: DemoCase): {
  chip: string;
  title: string;
  subtitle: string;
  accent: string;
} {
  if (demoCase.decision === "block") {
    return {
      chip: "Blocked",
      title: "This swap was reverted",
      subtitle:
        "The hook cancelled the swap before funds moved. The pool recorded no settlement.",
      accent: "#FF5370",
    };
  }
  if (demoCase.decision === "fee_override") {
    const feePct = (demoCase.appliedFeeBps / 100).toFixed(2);
    return {
      chip: "Extra fee",
      title: "This swap settles with a risk fee",
      subtitle: `The pool keeps 0.30%. Total intended friction on this swap is ${feePct}%.`,
      accent: "#F0B90B",
    };
  }
  return {
    chip: "Allowed",
    title: "This wallet swaps at the standard fee",
    subtitle:
      "Standard pool fee 0.30%. The operator file for this wallet stays at the minimum log.",
    accent: "#4DB6FF",
  };
}

/**
 * Opinion module: Compliance Officer Agent legal / technical opinion.
 * Scannable verdict first; legal jargon stays behind "Technical details".
 */
export function LegalOpinion({ demoCase }: Pick<Props, "demoCase">) {
  const verdict = verdictCopy(demoCase);
  const chrome = opinionChrome(demoCase.decision);
  const opinion = demoCase.agent.technicalOpinion;
  const record = demoCase.agent.decisionRecord;
  const annex = demoCase.agent.sarAnnex;
  const legal = formalLegalOpinion(demoCase);
  const feeLabel =
    demoCase.decision === "block"
      ? "No settlement"
      : `${(demoCase.appliedFeeBps / 100).toFixed(2)}%`;

  const initials = walletInitials(demoCase.wallet, demoCase.walletLabel);

  return (
    <section className="relative mx-auto w-full max-w-[1000px] pb-2 pt-0 md:-translate-x-3">
      <div className="grid items-start gap-8 md:grid-cols-[minmax(0,1.5fr)_minmax(0,0.72fr)] md:gap-14">
        <div
          className="radius-a surface border-l-[1.5px] px-[22px] py-[22px] md:px-8 md:py-7"
          style={{
            borderColor: chrome.accent,
          }}
        >
          <div
            className="text-[13px] font-medium"
            style={{
              color: chrome.accent,
            }}
          >
            {verdict.chip}
          </div>
          <h3 className="mt-[10px] font-serif text-balance text-[26px] font-normal leading-tight tracking-tight text-uni-pink md:text-[28px]">
            {verdict.title}
          </h3>
          <p className="mt-[10px] max-w-xl text-[15px] font-normal leading-relaxed text-uni-muted">
            {verdict.subtitle}
          </p>

          <div className="mt-[22px]">
            <span className="label-kicker">Swap</span>
            <div className="mt-2 font-serif text-[22px] font-normal leading-snug text-uni-pink">
              {demoCase.swapSell} {demoCase.sellToken}
              <span className="mx-1.5 text-uni-muted">→</span>
              {demoCase.swapBuy} {demoCase.buyToken}
            </div>
          </div>

          <div className="mt-[28px]">
            <p className="label-kicker">
              Score
            </p>
            <p className="mt-2 font-serif text-[48px] leading-none tracking-tight text-uni-pink">
              {demoCase.score}
              <span className="ml-1 text-[16px] font-normal text-uni-muted">
                / 100
              </span>
            </p>
            <div className="mt-[12px] h-px w-full bg-uni-pink/[0.08]">
              <div
                className="h-px"
                style={{
                  width: `${Math.min(100, Math.max(0, demoCase.score))}%`,
                  background: chrome.accent,
                }}
              />
            </div>
          </div>
        </div>

        <aside className="radius-d border-t hair px-1 py-5 md:mt-10">
          <div className="mb-[22px] flex items-center gap-[10px]">
            <span
              className="flex h-[34px] w-[34px] items-center justify-center text-[13px] font-medium"
              style={{
                background: chrome.markBg,
                color: chrome.markFg,
                borderRadius: "14px 2px 10px 2px",
              }}
              aria-hidden
            >
              {initials}
            </span>
            <span className="label-kicker">Subject</span>
          </div>
          <div className="flex flex-col gap-[22px]">
            <MetaCell label="Wallet" value={demoCase.walletLabel} />
            <MetaCell label="Fee this swap" value={feeLabel} />
            <MetaCell label="Look again" value={record.nextReview} />
          </div>
        </aside>
      </div>

      <div className="mt-12 grid gap-x-10 gap-y-8 md:grid-cols-2">
        <StoryCard
          question="Who is this wallet?"
          answer={softenNarrative(opinion.objectAndScope)}
        />
        <StoryCard
          question="What did they do?"
          answer={softenNarrative(opinion.typologies)}
        />
        <StoryCard
          question="Why this decision?"
          answer={softenNarrative(opinion.riskAndScoring)}
        />
        <StoryCard
          question="What did the hook do?"
          answer={softenNarrative(opinion.decisionExecuted)}
        />
      </div>

      {annex ? (
        <div className="radius-g mt-10 border-t hair px-1 py-6 md:px-2">
          <details className="group">
            <summary className="cursor-pointer list-none text-center text-[15px] font-medium text-uni-pink [&::-webkit-details-marker]:hidden">
              Extra review file · drafted, not filed
              <span className="ml-2 text-[13px] font-normal text-uni-muted group-open:hidden">
                · open to read
              </span>
            </summary>
            <div className="mt-6 space-y-6">
              <div className="grid gap-6 sm:grid-cols-2">
                <MetaCell label="Status" value={annex.status} />
                <MetaCell label="Operation" value={annex.operationState} />
                <MetaCell label="Period" value={annex.activityPeriod} />
                <MetaCell label="Amount" value={annex.amountInvolved} />
              </div>
              <OpinionRow
                label="What we saw"
                value={softenNarrative(annex.narrativeDescription)}
              />
              <OpinionRow
                label="Why it matters"
                value={softenNarrative(annex.narrativeEvidence)}
              />
              <OpinionRow
                label="Closing"
                value={softenNarrative(annex.narrativeConclusion)}
              />
            </div>
          </details>
        </div>
      ) : null}

      <article className="mx-auto mt-16 max-w-[720px] pb-8">
        <p className="text-center text-[12px] font-medium tracking-[0.16em] text-uni-muted">
          Issued to {demoCase.agent.recipient}
        </p>
        <h4 className="mt-3 text-center font-serif text-[32px] font-normal tracking-tight text-uni-pink md:text-[40px]">
          {legal.title}
        </h4>
        <div className="mt-8 grid gap-6 border-t hair py-7 sm:grid-cols-3 sm:text-left">
          <MetaCell label="Disposition" value={record.output} />
          <MetaCell label="Score" value={`${record.score} / 100`} />
          <MetaCell label="Record hash" value={demoCase.agent.auditHash} mono />
        </div>
        <div className="mt-10 space-y-6 text-[16px] font-normal leading-[1.85] text-uni-pink/85">
          <p>{legal.finding}</p>
          <p>{legal.nature}</p>
        </div>
        <div className="mt-12 space-y-8">
          <OpinionRow label="Legal basis" value={legal.basis} />
          {(opinion.normativeCitations?.length ?? 0) > 0 ? (
            <div>
              <div className="font-serif text-[17px] text-uni-pink">
                Normative basis
              </div>
              <ul className="mt-3 space-y-3">
                {opinion.normativeCitations!.map((cite) => (
                  <li key={cite.id}>
                    <p className="text-[15px] font-normal leading-relaxed text-uni-muted">
                      {cite.title}
                    </p>
                    <p className="mt-1 font-mono text-[12px] text-uni-muted/80">
                      {cite.id} · {cite.framework} · published{" "}
                      {cite.publicationDate} · retrieved{" "}
                      {cite.retrievedAt.slice(0, 10)}
                    </p>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          <OpinionRow label="Directions to the operator" value={legal.directions} />
          <OpinionRow label="Record and retention" value={legal.traceability} />
        </div>

        <details className="group mt-14 border-t hair pt-6">
          <summary className="cursor-pointer list-none text-center text-[13px] text-uni-muted transition hover:text-uni-pink [&::-webkit-details-marker]:hidden">
            Technical details
            <span className="ml-1.5 group-open:hidden">· hash, timing, venue</span>
          </summary>
          <div className="mt-6 space-y-6">
            <div className="grid gap-6 sm:grid-cols-3 sm:text-left">
              <MetaCell label="Recipient" value={demoCase.agent.recipient} />
              <MetaCell label="Audit hash" value={demoCase.agent.auditHash} mono />
              <MetaCell
                label="Retention"
                value={`${demoCase.agent.retentionYears} years`}
              />
            </div>
            {demoCase.agent.run ? (
              <div className="grid gap-6 sm:grid-cols-3 sm:text-left">
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
                  value={demoCase.agent.run.publishTxHash ?? "n/a"}
                  mono
                />
              </div>
            ) : null}
            <OpinionRow
              label="When"
              value={softenNarrative(opinion.sanctionsCheck)}
            />
            <OpinionRow
              label="Where"
              value={softenNarrative(opinion.sourcesConsulted.join(" "))}
            />
          </div>
        </details>
      </article>
    </section>
  );
}

/** @deprecated Prefer AmlStats / LegalOpinion: kept as thin router. */
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
    <div>
      <div className="label-kicker">{label}</div>
      <div
        className={`mt-1.5 text-[17px] font-normal leading-snug text-uni-pink ${mono ? "font-mono text-[13px]" : "font-serif"}`}
      >
        {value}
      </div>
    </div>
  );
}

function StoryCard({
  question,
  answer,
}: {
  question: string;
  answer: string;
}) {
  return (
    <div>
      <h4 className="font-serif text-[18px] text-uni-pink">{question}</h4>
      <p className="mt-[10px] text-[15px] font-normal leading-relaxed text-uni-muted">
        {answer}
      </p>
    </div>
  );
}

function OpinionRow({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="font-serif text-[17px] text-uni-pink">{label}</div>
      <p className="mt-2 text-[15px] font-normal leading-relaxed text-uni-muted">
        {value}
      </p>
    </div>
  );
}
