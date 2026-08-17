"use client";

import { useEffect, useState } from "react";
import { DEMO_STAGES, type DemoStage } from "@/components/StageRail";

const MANUAL = new Set<DemoStage>([
  "swap",
  "hook",
  "fees",
  "stats",
  "opinion",
  "event",
]);
const ORDER = DEMO_STAGES.map((s) => s.id);

type Hint = {
  zone: "up" | "down";
  label: string;
  active: boolean;
};

type Props = {
  stage: DemoStage;
  unlockedThrough: DemoStage;
  /** Hide while connect / MetaMask modals are open */
  disabled?: boolean;
};

/**
 * Floating cursor hint for stage click navigation (Swap → … → Event).
 * Upper half = previous screen; lower half = next screen.
 */
export function StageNavCursor({
  stage,
  unlockedThrough,
  disabled = false,
}: Props) {
  const [pos, setPos] = useState({ x: 0, y: 0 });
  const [hint, setHint] = useState<Hint | null>(null);
  const [visible, setVisible] = useState(false);

  const [desktopPointer, setDesktopPointer] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia("(hover: hover) and (pointer: fine) and (min-width: 1024px)");
    const sync = () => setDesktopPointer(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  const enabled = !disabled && desktopPointer && MANUAL.has(stage);

  useEffect(() => {
    if (!enabled) {
      setVisible(false);
      setHint(null);
      document.documentElement.classList.remove("stage-nav-cursor");
      return;
    }

    document.documentElement.classList.add("stage-nav-cursor");

    const isInteractive = (el: EventTarget | null) => {
      if (!(el instanceof Element)) return false;
      return Boolean(
        el.closest(
          "a, button, input, textarea, select, label, [role='button'], nav, [data-no-stage-nav]",
        ),
      );
    };

    const resolveHint = (
      clientY: number,
      target: EventTarget | null,
    ): Hint | null => {
      if (isInteractive(target)) return null;

      const upper = clientY < window.innerHeight / 2;
      const idx = ORDER.indexOf(stage);
      const unlockedIdx = ORDER.indexOf(unlockedThrough);
      const maxScroll = Math.max(
        0,
        document.documentElement.scrollHeight - window.innerHeight,
      );
      const atBottom = window.scrollY >= maxScroll - 40;

      if (upper) {
        const prev = idx > 0 ? ORDER[idx - 1] : null;
        if (!prev) return null;
        const prevLabel =
          DEMO_STAGES.find((s) => s.id === prev)?.label ?? "Previous";
        return { zone: "up", label: prevLabel, active: true };
      }

      const next = idx < ORDER.length - 1 ? ORDER[idx + 1] : null;
      if (!next) return null;
      const unlocked = ORDER.indexOf(next) <= unlockedIdx;
      const nextLabel =
        DEMO_STAGES.find((s) => s.id === next)?.label ?? "Next";

      // Opinion → Event: hint only active at end of module
      const opinionGate = stage === "opinion" ? atBottom : true;

      return {
        zone: "down",
        label: opinionGate ? nextLabel : "Scroll to end",
        active: unlocked && opinionGate,
      };
    };

    let lastX = 0;
    let lastY = 0;
    let lastTarget: EventTarget | null = null;

    const refresh = () => {
      const nextHint = resolveHint(lastY, lastTarget);
      setHint(nextHint);
      setVisible(Boolean(nextHint));
      if (!nextHint) {
        document.documentElement.style.cursor = "";
      } else if (!nextHint.active) {
        document.documentElement.style.cursor = "default";
      } else {
        document.documentElement.style.cursor =
          nextHint.zone === "up" ? "n-resize" : "s-resize";
      }
    };

    const onMove = (e: MouseEvent) => {
      lastX = e.clientX;
      lastY = e.clientY;
      lastTarget = e.target;
      setPos({ x: lastX, y: lastY });
      refresh();
    };

    const onScroll = () => refresh();

    const onLeave = () => {
      setVisible(false);
      document.documentElement.style.cursor = "";
    };

    window.addEventListener("mousemove", onMove);
    window.addEventListener("scroll", onScroll, { passive: true });
    document.documentElement.addEventListener("mouseleave", onLeave);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("scroll", onScroll);
      document.documentElement.removeEventListener("mouseleave", onLeave);
      document.documentElement.classList.remove("stage-nav-cursor");
      document.documentElement.style.cursor = "";
    };
  }, [enabled, stage, unlockedThrough]);

  if (!enabled || !visible || !hint) return null;

  const arrow = hint.zone === "up" ? "↑" : "↓";
  const offsetY = hint.zone === "up" ? -52 : 28;

  return (
    <div
      aria-hidden
      className={`stage-nav-hint pointer-events-none fixed z-[80] flex items-center gap-2 rounded-full px-3 py-1.5 text-[11px] font-semibold uppercase tracking-wider shadow-[0_8px_28px_rgba(0,0,0,0.45)] backdrop-blur-md transition-[opacity,transform] duration-150 ${
        hint.active
          ? "border border-uni-pink/40 bg-[#1a0b18]/92 text-uni-pink"
          : "border border-white/10 bg-black/70 text-uni-muted"
      }`}
      style={{
        left: pos.x,
        top: pos.y,
        transform: `translate(14px, ${offsetY}px)`,
      }}
    >
      <span
        className={`flex h-5 w-5 items-center justify-center rounded-full text-sm leading-none ${
          hint.active ? "bg-uni-pink/25" : "bg-white/10"
        }`}
      >
        {arrow}
      </span>
      <span>{hint.label}</span>
    </div>
  );
}
