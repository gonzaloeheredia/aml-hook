"use client";

import type { CSSProperties } from "react";
import type { Decision, DemoCase } from "@/data/cases";

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

function opinionChrome(decision: Decision) {
  const accent =
    decision === "block"
      ? "#FF5370"
      : decision === "fee_override"
        ? "#F0B90B"
        : "#4DB6FF";

  return {
    accent,
    verdictBg: "linear-gradient(145deg, #13263d 0%, #0a1522 45%, #050a12 100%)",
    verdictBorder: `${accent}55`,
    markBg: "#FC72FF",
    markFg: "#000000",
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
 * Formal closing opinion for the operator record — not a SAR and not a filing.
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
      title: "This swap was stopped",
      subtitle:
        "The hook reverted before any funds moved. Nothing was settled on the pool.",
      accent: "#FF5370",
    };
  }
  if (demoCase.decision === "fee_override") {
    const feePct = (demoCase.appliedFeeBps / 100).toFixed(2);
    return {
      chip: "Extra fee",
      title: "This swap can go through, with extra friction",
      subtitle: `Standard 0.30% plus a risk differential — about ${feePct}% total on this swap.`,
      accent: "#F0B90B",
    };
  }
  return {
    chip: "Allowed",
    title: "This wallet can swap normally",
    subtitle:
      "Standard pool fee 0.30%. No extra review file was opened for this wallet.",
    accent: "#4DB6FF",
  };
}

/**
 * Opinion module — Compliance Officer Agent legal / technical opinion.
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
    <section className="relative mx-auto w-full max-w-[1000px] pb-2 pt-0">
      <div className="grid items-start gap-[18px] md:grid-cols-[minmax(0,1.45fr)_minmax(0,0.82fr)]">
        <div
          className="rounded-[20px] border px-[22px] py-[18px] md:px-7 md:py-[22px]"
          style={{
            borderColor: chrome.verdictBorder,
            background: chrome.verdictBg,
            boxShadow:
              "7px 16px 34px rgba(0, 0, 0, 0.22), -2px 3px 10px rgba(0, 0, 0, 0.15)",
          }}
        >
          <div
            className="pl-[10px] text-[13px] font-semibold"
            style={{
              borderLeft: `3px solid ${chrome.accent}`,
              color: chrome.accent,
            }}
          >
            {verdict.chip}
          </div>
          <h3 className="mt-[10px] text-balance text-[26px] font-bold leading-tight tracking-tight text-white md:text-[28px]">
            {verdict.title}
          </h3>
          <p className="mt-[10px] max-w-xl text-[15px] font-normal leading-relaxed text-white/70">
            {verdict.subtitle}
          </p>

          <div className="mt-[18px] flex flex-wrap items-baseline gap-x-[10px] gap-y-1">
            <span className="text-[13px] font-semibold text-white/55">Swap</span>
            <span className="text-[17px] font-normal text-white">
              {demoCase.swapSell} {demoCase.sellToken}
              <span className="mx-1.5 text-white/35">→</span>
              {demoCase.swapBuy} {demoCase.buyToken}
            </span>
          </div>

          <div className="mt-[28px]">
            <p className="text-[13px] font-semibold text-white/55">
              Score {demoCase.score}
              <span className="ml-1 text-[11px] font-normal text-white/40">
                / 100
              </span>
            </p>
            <div className="mt-[10px] h-[3px] w-full bg-white/10">
              <div
                className="h-full"
                style={{
                  width: `${Math.min(100, Math.max(0, demoCase.score))}%`,
                  background: chrome.accent,
                }}
              />
            </div>
          </div>
        </div>

        <aside
          className="rounded-[8px] border border-uni-border bg-uni-card px-[18px] py-[18px]"
          style={{
            boxShadow: "3px 11px 24px rgba(0, 0, 0, 0.2)",
          }}
        >
          <div className="mb-[18px] flex items-center gap-[10px]">
            <span
              className="flex h-[34px] w-[34px] items-center justify-center rounded-[4px] text-[13px] font-semibold"
              style={{ background: chrome.markBg, color: chrome.markFg }}
              aria-hidden
            >
              {initials}
            </span>
            <span className="text-[13px] font-semibold text-white">Subject</span>
          </div>
          <div className="flex flex-col gap-[18px]">
            <MetaCell label="Wallet" value={demoCase.walletLabel} />
            <MetaCell label="Fee this swap" value={feeLabel} />
            <MetaCell label="Look again" value={record.nextReview} />
          </div>
        </aside>
      </div>

      <div className="mt-[18px] grid gap-[18px] md:grid-cols-2">
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
        <div
          className="mt-[18px] rounded-[8px] border border-uni-border bg-uni-card px-[22px] py-[18px] md:px-6"
          style={{ boxShadow: "4px 12px 26px rgba(0, 0, 0, 0.18)" }}
        >
          <details className="group">
            <summary className="cursor-pointer list-none text-[15px] font-semibold text-white [&::-webkit-details-marker]:hidden">
              Extra review file · drafted, not filed
              <span className="ml-[10px] text-[13px] font-normal text-uni-muted group-open:hidden">
                — tap to read
              </span>
            </summary>
            <div className="mt-[18px] space-y-[18px]">
              <div className="grid gap-[10px] sm:grid-cols-2">
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

      <details
        className="group mt-[18px] rounded-[8px] border border-uni-border bg-[#131313] px-[22px] py-[18px] md:px-6"
        style={{ boxShadow: "2px 8px 20px rgba(0, 0, 0, 0.16)" }}
      >
        <summary className="cursor-pointer list-none text-[13px] font-semibold text-uni-muted [&::-webkit-details-marker]:hidden">
          Technical details
          <span className="ml-1.5 font-normal group-open:hidden">
            · hash, timing, venue
          </span>
        </summary>
        <div className="mt-[18px] space-y-[18px]">
          <div className="grid gap-[10px] sm:grid-cols-3">
            <MetaCell label="Recipient" value={demoCase.agent.recipient} />
            <MetaCell label="Audit hash" value={demoCase.agent.auditHash} mono />
            <MetaCell
              label="Retention"
              value={`${demoCase.agent.retentionYears} years`}
            />
          </div>
          {demoCase.agent.run ? (
            <div className="grid gap-[10px] sm:grid-cols-3">
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

      <article
        className="mt-[28px] rounded-[8px] border border-uni-border bg-uni-card px-[22px] py-[22px] md:px-7 md:py-[28px]"
        style={{
          boxShadow:
            "8px 18px 36px rgba(0, 0, 0, 0.24), -1px 4px 12px rgba(0, 0, 0, 0.15)",
        }}
      >
        <p className="text-[13px] font-semibold text-uni-muted">
          Issued to {demoCase.agent.recipient}
        </p>
        <h4 className="mt-[10px] text-[22px] font-semibold tracking-tight text-white">
          {legal.title}
        </h4>
        <div className="mt-[18px] grid gap-[10px] border-y border-uni-border py-[18px] sm:grid-cols-3">
          <MetaCell label="Disposition" value={record.output} />
          <MetaCell label="Score" value={`${record.score} / 100`} />
          <MetaCell label="Record hash" value={demoCase.agent.auditHash} mono />
        </div>
        <div className="mt-[18px] space-y-[18px] text-[15px] font-normal leading-relaxed text-white/85">
          <p>{legal.finding}</p>
          <p>{legal.nature}</p>
        </div>
        <div className="mt-[28px] space-y-[18px]">
          <OpinionRow label="Legal basis" value={legal.basis} />
          <OpinionRow label="Directions to the operator" value={legal.directions} />
          <OpinionRow label="Record and retention" value={legal.traceability} />
        </div>
      </article>
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
    <div>
      <div className="text-[13px] font-semibold text-uni-muted">{label}</div>
      <div
        className={`mt-1.5 text-[17px] font-normal leading-snug text-white ${mono ? "font-mono text-[13px]" : ""}`}
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
    <div
      className="rounded-[8px] border border-uni-border bg-uni-card px-[18px] py-[18px] md:px-5"
      style={{ boxShadow: "3px 10px 22px rgba(0, 0, 0, 0.18)" }}
    >
      <h4 className="text-[15px] font-semibold text-white">{question}</h4>
      <p className="mt-[10px] text-[15px] font-normal leading-relaxed text-white/75">
        {answer}
      </p>
    </div>
  );
}

function OpinionRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-uni-border/70 pb-[10px] last:border-0 last:pb-0">
      <div className="text-[13px] font-semibold text-uni-muted">{label}</div>
      <p className="mt-1.5 text-[15px] font-normal leading-relaxed text-white/90">
        {value}
      </p>
    </div>
  );
}
