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
  { id: "hook", label: "hook execution", hint: "beforeSwap" },
  { id: "fees", label: "Fees", hint: "FeeEscrow differential" },
  { id: "stats", label: "Stats", hint: "Score · detection" },
  { id: "opinion", label: "Opinion", hint: "Legal / technical opinion" },
  { id: "event", label: "Event", hint: "afterSwap payload · pool chain" },
];

type Props = {
  stage: DemoStage;
  /** Highest stage the user has reached (inclusive): earlier steps stay clickable */
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
 * Demo stage stepper. Horizontal timeline: always-visible labels,
 * progress-split connector, three node states (done / active / pending).
 */
export function StageRail({ stage, unlockedThrough, onSelect }: Props) {
  const activeIndex = ORDER.indexOf(stage);
  const count = DEMO_STAGES.length;
  const insetPct = 100 / (count * 2);
  const cutPct =
    count <= 1 || activeIndex <= 0 ? 0 : (activeIndex / (count - 1)) * 100;

  return (
    <nav aria-label="Demo stages" className="w-full">
      <ol className="relative mx-auto flex w-full flex-row items-start">
        <span
          aria-hidden
          className="pointer-events-none absolute h-px"
          style={{
            left: `${insetPct}%`,
            right: `${insetPct}%`,
            top: 19,
            background: `linear-gradient(to right, rgb(var(--ink) / 0.25) ${cutPct}%, rgb(var(--ink) / 0.08) ${cutPct}%)`,
          }}
        />
        {DEMO_STAGES.map((s) => {
          const active = s.id === stage;
          const unlocked = isUnlocked(s.id, unlockedThrough);
          const completed =
            unlocked && ORDER.indexOf(s.id) < ORDER.indexOf(stage);

          return (
            <li key={s.id} className="relative min-w-0 flex-1">
              <button
                type="button"
                disabled={!unlocked}
                onClick={() => unlocked && onSelect(s.id)}
                aria-current={active ? "step" : undefined}
                title={s.hint}
                className={`flex w-full flex-col items-center gap-1.5 px-1 py-1.5 text-center transition ${
                  unlocked ? "" : "cursor-not-allowed"
                }`}
              >
                <span className="relative z-[1] flex h-[22px] w-[22px] shrink-0 items-center justify-center bg-uni-bg">
                  {completed ? (
                    <span className="block h-2 w-2 rounded-full bg-uni-pink" />
                  ) : active ? (
                    <span className="flex h-[22px] w-[22px] items-center justify-center rounded-full border-2 border-uni-pink bg-transparent">
                      <span className="block h-1.5 w-1.5 rounded-full bg-uni-pink" />
                    </span>
                  ) : (
                    <span className="block h-[22px] w-[22px] rounded-full border border-uni-pink/[0.12] bg-transparent" />
                  )}
                </span>
                <span
                  className={`text-[10px] font-medium uppercase leading-tight tracking-[0.06em] sm:text-[11px] ${
                    active ? "text-uni-pink" : "text-uni-pink/35"
                  }`}
                >
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
