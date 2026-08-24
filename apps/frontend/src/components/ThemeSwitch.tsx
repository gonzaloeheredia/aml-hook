"use client";

import { useEffect, useState } from "react";

type Theme = "dark" | "light";

function readTheme(): Theme {
  if (typeof document === "undefined") return "dark";
  return document.documentElement.getAttribute("data-theme") === "light"
    ? "light"
    : "dark";
}

function applyTheme(next: Theme) {
  if (next === "light") {
    document.documentElement.setAttribute("data-theme", "light");
  } else {
    document.documentElement.removeAttribute("data-theme");
  }
  try {
    localStorage.setItem("aml-theme", next);
  } catch {
    /* ignore quota / private mode */
  }
}

/**
 * On/off theme button. Default is dark (off); light is on.
 */
export function ThemeSwitch() {
  const [theme, setTheme] = useState<Theme>("dark");

  useEffect(() => {
    setTheme(readTheme());
  }, []);

  const isLight = theme === "light";

  return (
    <button
      type="button"
      aria-pressed={isLight}
      data-no-stage-nav
      title={isLight ? "Turn off light" : "Turn on light"}
      aria-label={isLight ? "Turn off light theme" : "Turn on light theme"}
      onClick={() => {
        const next: Theme = isLight ? "dark" : "light";
        applyTheme(next);
        setTheme(next);
      }}
      className="theme-power shrink-0"
    >
      <span className="theme-power-glyph" aria-hidden>
        {isLight ? <MoonIcon /> : <SunIcon />}
      </span>
    </button>
  );
}

function MoonIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none">
      <path
        d="M17.4 15.2A7.2 7.2 0 0 1 8.8 6.6 7.25 7.25 0 1 0 17.4 15.2Z"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function SunIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="3.4" stroke="currentColor" strokeWidth="1.6" />
      <path
        d="M12 4.2v1.6M12 18.2v1.6M4.2 12h1.6M18.2 12h1.6M6.5 6.5l1.1 1.1M16.4 16.4l1.1 1.1M6.5 17.5l1.1-1.1M16.4 7.6l1.1-1.1"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
      />
    </svg>
  );
}
