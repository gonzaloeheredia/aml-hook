"use client";

import { useEffect, useState } from "react";
import { DEMO_STAGES, type DemoStage } from "@/components/StageRail";

const ORDER = DEMO_STAGES.map((s) => s.id);

type Box = {
  prevX: number;
  nextX: number;
  midY: number;
};

type Props = {
  stage: DemoStage;
  unlockedThrough: DemoStage;
  disabled?: boolean;
  onPrev: () => void;
  onNext: () => void;
};

function Chevron({ dir }: { dir: "prev" | "next" }) {
  return (
    <svg width="18" height="36" viewBox="0 0 18 36" fill="none" aria-hidden>
      <path
        d={dir === "prev" ? "M12.5 3.5 L4 18 L12.5 32.5" : "M5.5 3.5 L14 18 L5.5 32.5"}
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function labelFor(id: DemoStage | undefined) {
  return DEMO_STAGES.find((s) => s.id === id)?.label ?? "";
}

/**
 * Prev / next chevrons glued to the visible sides of the current info module.
 */
export function StageSideNav({
  stage,
  unlockedThrough,
  disabled = false,
  onPrev,
  onNext,
}: Props) {
  const [box, setBox] = useState<Box | null>(null);
  const [atBottom, setAtBottom] = useState(true);
  const [desktop, setDesktop] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia("(min-width: 768px)");
    const sync = () => setDesktop(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  useEffect(() => {
    const measure = () => {
      const maxScroll = Math.max(
        0,
        document.documentElement.scrollHeight - window.innerHeight,
      );
      setAtBottom(window.scrollY >= maxScroll - 40);

      const el = document.querySelector("[data-stage-module]");
      if (!(el instanceof HTMLElement)) {
        setBox(null);
        return;
      }

      const r = el.getBoundingClientRect();
      const visibleTop = Math.max(r.top, 96);
      const visibleBottom = Math.min(r.bottom, window.innerHeight - 28);
      if (visibleBottom - visibleTop < 48) {
        setBox(null);
        return;
      }

      setBox({
        prevX: Math.max(8, r.left - 40),
        nextX: Math.min(window.innerWidth - 44, r.right + 6),
        midY: (visibleTop + visibleBottom) / 2,
      });
    };

    measure();
    const ro = new ResizeObserver(measure);
    const root = document.querySelector("main");
    if (root) ro.observe(root);

    window.addEventListener("scroll", measure, { passive: true });
    window.addEventListener("resize", measure);

    const started = performance.now();
    let raf = 0;
    const tick = (now: number) => {
      measure();
      if (now - started < 6200) raf = window.requestAnimationFrame(tick);
    };
    raf = window.requestAnimationFrame(tick);

    return () => {
      ro.disconnect();
      window.removeEventListener("scroll", measure);
      window.removeEventListener("resize", measure);
      window.cancelAnimationFrame(raf);
    };
  }, [stage]);

  if (disabled || !desktop || !box) return null;

  const idx = ORDER.indexOf(stage);
  const unlockedIdx = ORDER.indexOf(unlockedThrough);
  const prev = idx > 0 ? ORDER[idx - 1] : undefined;
  const next = idx < ORDER.length - 1 ? ORDER[idx + 1] : undefined;
  const nextUnlocked = next ? ORDER.indexOf(next) <= unlockedIdx : false;
  const opinionGate = stage === "opinion" ? atBottom : true;
  const nextActive = Boolean(next && nextUnlocked && opinionGate);

  const btn =
    "fixed z-[25] flex h-14 w-10 items-center justify-center text-uni-pink/30 transition-colors duration-200 hover:text-uni-pink/65 focus-visible:outline-none focus-visible:text-uni-pink/80 disabled:pointer-events-none disabled:text-uni-pink/12";

  return (
    <>
      {prev && (
        <button
          type="button"
          aria-label={`Previous · ${labelFor(prev)}`}
          title={labelFor(prev)}
          onClick={onPrev}
          className={btn}
          style={{ left: box.prevX, top: box.midY, transform: "translateY(-50%)" }}
        >
          <Chevron dir="prev" />
        </button>
      )}
      {next && (
        <button
          type="button"
          aria-label={
            nextActive
              ? `Next · ${labelFor(next)}`
              : stage === "opinion"
                ? "Scroll to end"
                : `Next · ${labelFor(next)}`
          }
          title={nextActive ? labelFor(next) : undefined}
          disabled={!nextActive}
          onClick={onNext}
          className={btn}
          style={{ left: box.nextX, top: box.midY, transform: "translateY(-50%)" }}
        >
          <Chevron dir="next" />
        </button>
      )}
    </>
  );
}
