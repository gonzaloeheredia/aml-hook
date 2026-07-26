"use client";

import { CASE_ORDER, DEMO_CASES, type DemoCaseId } from "@/data/cases";

type Props = {
  active: DemoCaseId;
  /** Switches the active demo case and connected address */
  onChange: (id: DemoCaseId) => void;
};

/** Visual accent styles for each case circle (active state) */
const TONE: Record<
  DemoCaseId,
  { ring: string; text: string; soft: string }
> = {
  clean: {
    ring: "border-uni-ok shadow-[0_0_0_4px_rgba(64,182,107,0.18)]",
    text: "text-uni-ok",
    soft: "bg-uni-ok/15",
  },
  structuring: {
    ring: "border-uni-warn shadow-[0_0_0_4px_rgba(240,185,11,0.18)]",
    text: "text-uni-warn",
    soft: "bg-uni-warn/15",
  },
  ofac: {
    ring: "border-uni-bad shadow-[0_0_0_4px_rgba(255,83,112,0.18)]",
    text: "text-uni-bad",
    soft: "bg-uni-bad/15",
  },
};

/**
 * Vertical stack of three circular case selectors (left of the simulator).
 * Shown only after a wallet is connected; each circle maps to one demo address.
 */
export function CaseSwitcher({ active, onChange }: Props) {
  return (
    <aside className="flex flex-col items-start gap-5">
      {CASE_ORDER.map((id, index) => {
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
              {index + 1}
            </span>
            <span className="flex flex-col items-start text-left">
              <span
                className={`text-[10px] font-semibold uppercase tracking-wider ${
                  isActive ? tone.text : "text-uni-muted"
                }`}
              >
                Case {index + 1}
              </span>
              <span
                className={`max-w-[7.5rem] text-xs font-semibold leading-tight ${
                  isActive ? "text-white" : "text-uni-muted group-hover:text-white"
                }`}
              >
                {c.shortLabel}
              </span>
            </span>
          </button>
        );
      })}
    </aside>
  );
}
