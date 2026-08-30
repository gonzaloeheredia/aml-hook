"use client";

import type { ReactNode } from "react";

type Props = {
  /** Remount key: changing this retriggers the slide */
  stageKey: string;
  /** 1 = next (enter from right); -1 = previous (enter from left) */
  direction?: 1 | -1;
  /** Triple-length slide when entering Opinion from the left (forward) */
  slow?: boolean;
  /** Going back: short slide from the left */
  swift?: boolean;
  children: ReactNode;
  className?: string;
};

/**
 * Stage panel: the next screen slides in from the right (page moves left);
 * going back slides in from the left.
 */
export function StageMorph({
  stageKey,
  direction = 1,
  slow = false,
  swift = false,
  children,
  className = "",
}: Props) {
  const slide =
    direction > 0 ? "stage-slide-in-right" : "stage-slide-in-left";
  const pace = swift ? " stage-slide-swift" : slow ? " stage-slide-slow" : "";

  return (
    <div className={`overflow-x-clip ${className}`}>
      <div key={stageKey} className={`${slide}${pace}`}>
        {children}
      </div>
    </div>
  );
}
