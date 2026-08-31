"use client";

import { useEffect, useState, type CSSProperties } from "react";
import { DEMO_STAGES, type DemoStage } from "@/components/StageRail";

const ORDER = DEMO_STAGES.map((s) => s.id);

type Side = "prev" | "next";

const EDGE_STYLE = {
  prev: {
    left: 16,
    top: "50%",
    transform: "translateY(-50%)",
  } satisfies CSSProperties,
  next: {
    right: 16,
    top: "50%",
    transform: "translateY(-50%)",
  } satisfies CSSProperties,
};

type Props = {
  stage: DemoStage;
  unlockedThrough: DemoStage;
  disabled?: boolean;
  onPrev: () => void;
  onNext: () => void;
};

function labelFor(id: DemoStage | undefined) {
  return DEMO_STAGES.find((s) => s.id === id)?.label ?? "";
}

function Arrow({ dir }: { dir: Side }) {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      aria-hidden
      className="stage-continue-fab__arrow"
    >
      {dir === "next" ? (
        <path
          d="M3 8h9M8.5 3.5 13 8l-4.5 4.5"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      ) : (
        <path
          d="M13 8H4M7.5 3.5 3 8l4.5 4.5"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )}
    </svg>
  );
}

function FabButton({
  dir,
  label,
  active,
  title,
  onClick,
  style,
}: {
  dir: Side;
  label: string;
  active: boolean;
  title?: string;
  onClick: () => void;
  style: CSSProperties;
}) {
  return (
    <div className="fixed z-30" style={style}>
      <button
        type="button"
        data-no-stage-nav
        disabled={!active}
        onClick={onClick}
        aria-label={
          dir === "next" ? `Continue to ${label}` : `Back to ${label}`
        }
        title={title ?? label}
        className={`stage-continue-fab radius-action edge surface inline-flex items-center gap-2 px-3.5 py-2.5 text-sm font-medium text-uni-pink ${
          dir === "next" ? "border-l" : "border-r stage-continue-fab--prev"
        } ${active ? "" : "pointer-events-none opacity-35"}`}
      >
        {dir === "prev" && <Arrow dir="prev" />}
        <span>{label}</span>
        {dir === "next" && <Arrow dir="next" />}
      </button>
    </div>
  );
}

/**
 * Prev / next controls pinned to the viewport edges at mid-screen.
 */
export function StageContinueFab({
  stage,
  unlockedThrough,
  disabled = false,
  onPrev,
  onNext,
}: Props) {
  const [visible, setVisible] = useState(false);
  const [atBottom, setAtBottom] = useState(true);

  useEffect(() => {
    const measure = () => {
      const maxScroll = Math.max(
        0,
        document.documentElement.scrollHeight - window.innerHeight,
      );
      setAtBottom(window.scrollY >= maxScroll - 40);

      const el = document.querySelector("[data-stage-module]");
      if (!(el instanceof HTMLElement)) {
        setVisible(false);
        return;
      }

      const r = el.getBoundingClientRect();
      const visibleTop = Math.max(r.top, 96);
      const visibleBottom = Math.min(r.bottom, window.innerHeight - 28);
      setVisible(visibleBottom - visibleTop >= 48);
    };

    measure();
    const ro = new ResizeObserver(measure);
    const stageModule = document.querySelector("[data-stage-module]");
    if (stageModule) ro.observe(stageModule);
    const root = document.querySelector("main");
    if (root) ro.observe(root);

    window.addEventListener("scroll", measure, { passive: true });
    window.addEventListener("resize", measure);

    const started = performance.now();
    let raf = 0;
    const tick = (now: number) => {
      measure();
      if (now - started < 2200) raf = window.requestAnimationFrame(tick);
    };
    raf = window.requestAnimationFrame(tick);

    return () => {
      ro.disconnect();
      window.removeEventListener("scroll", measure);
      window.removeEventListener("resize", measure);
      window.cancelAnimationFrame(raf);
    };
  }, [stage]);

  if (disabled || !visible || stage === "swap") return null;

  const idx = ORDER.indexOf(stage);
  const unlockedIdx = ORDER.indexOf(unlockedThrough);
  const prev = idx > 0 ? ORDER[idx - 1] : undefined;
  const next = idx < ORDER.length - 1 ? ORDER[idx + 1] : undefined;
  const nextUnlocked = next ? ORDER.indexOf(next) <= unlockedIdx : false;
  const opinionGate = stage === "opinion" ? atBottom : true;
  const nextActive = Boolean(next && nextUnlocked && opinionGate);

  return (
    <>
      {prev && (
        <FabButton
          dir="prev"
          label={labelFor(prev)}
          active
          onClick={onPrev}
          style={EDGE_STYLE.prev}
        />
      )}
      {next && nextUnlocked && (
        <FabButton
          dir="next"
          label={labelFor(next)}
          active={nextActive}
          title={
            nextActive
              ? labelFor(next)
              : stage === "opinion"
                ? "Scroll to end"
                : labelFor(next)
          }
          onClick={onNext}
          style={EDGE_STYLE.next}
        />
      )}
    </>
  );
}
