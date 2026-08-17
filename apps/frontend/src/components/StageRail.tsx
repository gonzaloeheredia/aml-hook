"use client";

export type DemoStage =
  | "swap"
  | "hook"
  | "fees"
  | "stats"
  | "opinion"
  | "event";

export const DEMO_STAGES: {
  id: DemoStage;
  label: string;
  hint: string;
}[] = [
  { id: "swap", label: "Swap", hint: "Get started" },
  { id: "hook", label: "Hook", hint: "beforeSwap" },
  { id: "fees", label: "Fees", hint: "FeeEscrow differential" },
  { id: "stats", label: "Stats", hint: "Score · detection" },
  { id: "opinion", label: "Opinion", hint: "Legal / technical opinion" },
  { id: "event", label: "Event", hint: "afterSwap payload · pool chain" },
];

type Props = {
  stage: DemoStage;
  /** Highest stage the user has reached (inclusive) — earlier steps stay clickable */
  unlockedThrough: DemoStage;
  onSelect: (stage: DemoStage) => void;
};

const ORDER: DemoStage[] = DEMO_STAGES.map((s) => s.id);

/**
 * Returns true when `target` is at or before `limit` in the demo sequence.
 */
function isUnlocked(target: DemoStage, limit: DemoStage) {
  return ORDER.indexOf(target) <= ORDER.indexOf(limit);
}

/**
 * Demo stage stepper. Horizontal on small screens. On desktop it stays collapsed
 * to the step number and expands the labels on hover / keyboard focus.
 */
export function StageRail({ stage, unlockedThrough, onSelect }: Props) {
  return (
    <nav
      aria-label="Demo stages"
      className="group/rail w-full rounded-2xl border border-uni-border bg-uni-card/80 p-1.5 shadow-[0_8px_32px_rgba(0,0,0,0.22)] backdrop-blur-md transition-[width] duration-200 ease-out lg:w-14 lg:hover:w-44 lg:focus-within:w-44"
    >
      <ol className="flex flex-row gap-0.5 overflow-x-auto [-ms-overflow-style:none] [scrollbar-width:none] lg:flex-col lg:overflow-visible [&::-webkit-scrollbar]:hidden">
        {DEMO_STAGES.map((s, i) => {
          const active = s.id === stage;
          const unlocked = isUnlocked(s.id, unlockedThrough);
          const step = String(i + 1).padStart(2, "0");

          return (
            <li key={s.id} className="min-w-[4.75rem] flex-1 lg:min-w-0 lg:flex-none">
              <button
                type="button"
                disabled={!unlocked}
                onClick={() => unlocked && onSelect(s.id)}
                aria-current={active ? "step" : undefined}
                title={s.hint}
                className={`flex min-h-11 w-full flex-row items-center justify-center gap-2 rounded-xl px-2 py-2 text-center transition ${
                  active
                    ? "bg-uni-pink/12 text-uni-pink"
                    : unlocked
                      ? "text-uni-muted hover:bg-white/[0.05] hover:text-white/85"
                      : "cursor-not-allowed text-uni-muted/35"
                }`}
              >
                <span
                  className={`text-[11px] font-semibold tabular-nums tracking-wider ${
                    active ? "text-uni-pink" : "text-white/40"
                  }`}
                >
                  {step}
                </span>
                <span className="text-[11px] font-semibold uppercase tracking-[0.14em] lg:max-w-0 lg:overflow-hidden lg:opacity-0 lg:transition-[max-width,opacity] lg:duration-200 lg:group-hover/rail:max-w-[7rem] lg:group-hover/rail:opacity-100 lg:group-focus-within/rail:max-w-[7rem] lg:group-focus-within/rail:opacity-100">
                  {s.label}
                </span>
              </button>
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
