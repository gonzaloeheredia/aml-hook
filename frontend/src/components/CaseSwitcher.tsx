"use client";

import { CASE_ORDER, DEMO_CASES, type DemoCaseId } from "@/data/cases";

type Props = {
  active: DemoCaseId;
  onChange: (id: DemoCaseId) => void;
};

/** Static accents by role: C clean · A exploit · B intermediary */
const TONE: Record<
  DemoCaseId,
  { ring: string; text: string; soft: string }
> = {
  C: {
    ring: "border-uni-ok shadow-[0_0_0_4px_rgba(64,182,107,0.18)]",
    text: "text-uni-ok",
    soft: "bg-uni-ok/15",
  },
  A: {
    ring: "border-uni-bad shadow-[0_0_0_4px_rgba(255,83,112,0.18)]",
    text: "text-uni-bad",
    soft: "bg-uni-bad/15",
  },
  B: {
    ring: "border-uni-warn shadow-[0_0_0_4px_rgba(240,185,11,0.18)]",
    text: "text-uni-warn",
    soft: "bg-uni-warn/15",
  },
};

/**
 * Vertical stack of A/B/C selectors (use-case roles: A exploit · B hop · C clean).
 */
export function CaseSwitcher({ active, onChange }: Props) {
  return (
    <aside className="flex flex-col items-start gap-5">
      {CASE_ORDER.map((id) => {
        const c = DEMO_CASES[id];
        const tone = TONE[id];
        const isActive = active === id;

        return (
          <button
            key={id}
            type="button"
            onClick={() => onChange(id)}
            title={c.label}
            aria-pressed={isActive}
            className="group flex flex-row items-center gap-3"
          >
            <span
              className={`flex h-14 w-14 items-center justify-center rounded-full border-2 text-sm font-bold transition md:h-16 md:w-16 ${
                isActive
                  ? `${tone.ring} ${tone.soft} ${tone.text}`
                  : "border-uni-border bg-uni-surface text-uni-muted group-hover:border-white/30 group-hover:text-white"
              }`}
            >
              {id}
            </span>
            <span className="flex flex-col items-start text-left">
              <span
                className={`text-[10px] font-semibold uppercase tracking-wider ${
                  isActive ? tone.text : "text-uni-muted"
                }`}
              >
                Wallet {id}
              </span>
              <span
                className={`max-w-[8.5rem] text-xs font-semibold leading-tight ${
                  isActive ? "text-white" : "text-uni-muted group-hover:text-white"
                }`}
              >
                {c.shortLabel.replace(/^Wallet [ABC] · /, "")}
              </span>
            </span>
          </button>
        );
      })}
    </aside>
  );
}
