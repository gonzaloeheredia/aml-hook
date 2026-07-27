import type { Config } from "tailwindcss";

export default {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        uni: {
          pink: "#FC72FF",
          pinkDim: "#9B3A9E",
          bg: "#000000",
          surface: "#131313",
          card: "#1B1B1B",
          cardHover: "#222222",
          border: "#2B2B2B",
          muted: "#9B9B9B",
          ok: "#40B66B",
          warn: "#F0B90B",
          bad: "#FF5370",
        },
      },
      fontFamily: {
        sans: ["var(--font-jakarta)", "system-ui", "sans-serif"],
      },
      boxShadow: {
        glow: "0 0 80px rgba(252, 114, 255, 0.18)",
      },
      keyframes: {
        fadeUp: {
          "0%": { opacity: "0", transform: "translateY(24px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        auditReveal: {
          "0%": {
            opacity: "0",
            transform: "translateY(40px) scale(0.98)",
            filter: "blur(6px)",
          },
          "100%": {
            opacity: "1",
            transform: "translateY(0) scale(1)",
            filter: "blur(0)",
          },
        },
        pulseNode: {
          "0%, 100%": { boxShadow: "0 0 0 0 rgba(252, 114, 255, 0.45)" },
          "50%": { boxShadow: "0 0 0 10px rgba(252, 114, 255, 0)" },
        },
        flowDash: {
          to: { strokeDashoffset: "-24" },
        },
      },
      animation: {
        fadeUp: "fadeUp 0.7s ease-out both",
        auditReveal: "auditReveal 0.95s cubic-bezier(0.22, 1, 0.36, 1) both",
        pulseNode: "pulseNode 1.8s ease-in-out infinite",
        flowDash: "flowDash 1s linear infinite",
      },
    },
  },
  plugins: [],
} satisfies Config;
