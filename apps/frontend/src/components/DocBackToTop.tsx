"use client";

import { useEffect, useState } from "react";

/**
 * Floating control to return to the top of the Whitepaper / Use of case module.
 */
export function DocBackToTop() {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const onScroll = () => setVisible(window.scrollY > 280);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  if (!visible) return null;

  return (
    <button
      type="button"
      onClick={() => {
        document.getElementById("doc-module")?.scrollIntoView({
          behavior: "smooth",
          block: "start",
        });
      }}
      title="Back to top"
      aria-label="Back to top of this module"
      className="radius-f surface fixed bottom-5 right-5 z-30 inline-flex items-center gap-2 border-l hair px-3 py-2 text-sm font-medium text-uni-pink transition hover:border-uni-pink/30"
    >
      <span aria-hidden>
        <svg
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M12 19V5" />
          <polyline points="5 12 12 5 19 12" />
        </svg>
      </span>
      <span className="hidden sm:inline">Top</span>
    </button>
  );
}
