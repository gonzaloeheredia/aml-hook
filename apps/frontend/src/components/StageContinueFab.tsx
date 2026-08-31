"use client";

type Props = {
  label: string;
  onContinue: () => void;
};

/**
 * Floating next-stage control. Replaces the under-rail “Click X to continue” line.
 */
export function StageContinueFab({ label, onContinue }: Props) {
  return (
    <button
      type="button"
      data-no-stage-nav
      onClick={onContinue}
      aria-label={`Continue to ${label}`}
      className="stage-continue-fab radius-action edge surface fixed bottom-20 right-5 z-30 inline-flex items-center gap-2 border-l px-3.5 py-2.5 text-sm font-medium text-uni-pink"
    >
      <span>{label}</span>
      <svg
        width="16"
        height="16"
        viewBox="0 0 16 16"
        fill="none"
        aria-hidden
        className="stage-continue-fab__arrow"
      >
        <path
          d="M3 8h9M8.5 3.5 13 8l-4.5 4.5"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </button>
  );
}
