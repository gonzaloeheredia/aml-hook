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
  { id: "stats", label: "AML stats", hint: "Score · detection" },
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
 * Vertical stage rail — text-only labels (no numbered circles).
 * Active step uses a soft pink pill highlight.
 */
export function StageRail({ stage, unlockedThrough, onSelect }: Props) {
  return (
    <nav aria-label="Demo stages" className="flex flex-col items-stretch gap-1.5">
      {DEMO_STAGES.map((s) => {
        const active = s.id === stage;
        const unlocked = isUnlocked(s.id, unlockedThrough);

        return (
          <button
            key={s.id}
            type="button"
            disabled={!unlocked}
            onClick={() => unlocked && onSelect(s.id)}
            aria-current={active ? "step" : undefined}
            title={s.hint}
            className={`w-full min-w-[4.25rem] rounded-xl px-2 py-2 transition ${
              active
                ? "bg-uni-pink/10 ring-1 ring-uni-pink/30 backdrop-blur-sm"
                : unlocked
                  ? "hover:bg-white/[0.04]"
                  : "cursor-not-allowed opacity-35"
            }`}
          >
            <span
              className={`block max-w-[5.5rem] text-center text-[9px] font-semibold uppercase leading-tight tracking-wider ${
                active ? "text-uni-pink/90" : "text-uni-muted/80"
              }`}
            >
              {s.label}
            </span>
          </button>
        );
      })}
    </nav>
  );
}
