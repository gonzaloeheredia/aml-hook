"use client";

import type { ReactNode } from "react";

type Props = {
  /** Remount key — changing this retriggers the enter morph */
  stageKey: string;
  children: ReactNode;
  className?: string;
};

/**
 * Stage panel with a single modern enter morph (fade + rise + slight deblur).
 * Respects prefers-reduced-motion via CSS.
 */
export function StageMorph({ stageKey, children, className = "" }: Props) {
  return (
    <div key={stageKey} className={`stage-morph ${className}`}>
      {children}
    </div>
  );
}
