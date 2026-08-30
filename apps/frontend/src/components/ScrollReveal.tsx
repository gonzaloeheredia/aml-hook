"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";

type Props = {
  children: ReactNode;
  className?: string;
  /** Extra delay once the block enters the viewport (ms) */
  delayMs?: number;
  /** Intersection threshold: lower = starts earlier while scrolling */
  threshold?: number;
};

/**
 * Returns true when the element is already (or nearly) in the viewport.
 * Used after the flow simulator finishes and scrollIntoView lands on AML analysis,
 * so nested sections still play the same fade transition as scroll-driven reveals.
 */
function isNearViewport(el: HTMLElement): boolean {
  const rect = el.getBoundingClientRect();
  const vh = window.innerHeight || 0;
  return rect.top < vh * 0.92 && rect.bottom > vh * 0.08;
}

/**
 * Slow fade/slide/blur reveal driven by scroll: content appears gradually
 * as the user moves the mouse wheel (or trackpad) downward into view.
 * Also reveals when already on-screen at mount (post-simulator transition).
 */
export function ScrollReveal({
  children,
  className = "",
  delayMs = 0,
  threshold = 0.12,
}: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    let revealed = false;
    const reveal = () => {
      if (revealed) return;
      revealed = true;
      setVisible(true);
      observer.unobserve(el);
    };

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) reveal();
      },
      {
        threshold,
        // Start revealing a bit before the block is fully on screen
        rootMargin: "0px 0px -8% 0px",
      },
    );

    observer.observe(el);

    // After flow → audit scrollIntoView, paint opacity-0 first, then reveal
    // so ALLOW / Legal opinion gets the same transition as FEE_OVERRIDE / REVERT.
    const raf = window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        if (isNearViewport(el)) reveal();
      });
    });

    return () => {
      window.cancelAnimationFrame(raf);
      observer.disconnect();
    };
  }, [threshold]);

  return (
    <div
      ref={ref}
      className={`scroll-reveal ${visible ? "is-visible" : ""} ${className}`}
      style={{ transitionDelay: visible ? `${delayMs}ms` : "0ms" }}
    >
      {children}
    </div>
  );
}
