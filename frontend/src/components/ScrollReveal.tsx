"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";

type Props = {
  children: ReactNode;
  className?: string;
  /** Extra delay once the block enters the viewport (ms) */
  delayMs?: number;
  /** Intersection threshold — lower = starts earlier while scrolling */
  threshold?: number;
};

/**
 * Slow fade/slide/blur reveal driven by scroll: content appears gradually
 * as the user moves the mouse wheel (or trackpad) downward into view.
 */
export function ScrollReveal({
  children,
  className = "",
  delayMs = 0,
  threshold = 0.15,
}: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setVisible(true);
          observer.unobserve(el);
        }
      },
      {
        threshold,
        // Start revealing a bit before the block is fully on screen
        rootMargin: "0px 0px -12% 0px",
      },
    );

    observer.observe(el);
    return () => observer.disconnect();
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
