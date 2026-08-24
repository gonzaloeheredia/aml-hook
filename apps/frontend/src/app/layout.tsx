import type { Metadata } from "next";
import Script from "next/script";
import { Inter, Newsreader } from "next/font/google";
import { IgnoreMetaMaskNoise } from "@/components/IgnoreMetaMaskNoise";
import "./globals.css";

/**
 * Body / UI — geometric sans. Headings — editorial serif.
 */
const sans = Inter({
  variable: "--font-sans",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
});

const serif = Newsreader({
  variable: "--font-serif",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  style: ["normal", "italic"],
});

export const metadata: Metadata = {
  title: "AML Hook · Uniswap Demo",
  description:
    "Visual demo of the AML Hook for Uniswap v4 — exploit cash-out detection, N-hop decay fees, and ternary ALLOW / FEE_OVERRIDE / REVERT.",
};

/**
 * Root layout: applies global font, dark background, and shared HTML shell.
 */
export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${sans.variable} ${serif.variable} bg-uni-bg font-sans text-uni-pink antialiased`}
      >
        <Script id="aml-theme" strategy="beforeInteractive">{`
(function () {
  try {
    if (localStorage.getItem("aml-theme") === "light") {
      document.documentElement.setAttribute("data-theme", "light");
    }
  } catch (e) {}
})();
        `}</Script>
        <Script id="ignore-metamask-noise" strategy="beforeInteractive">{`
(function () {
  function isNoise(reason) {
    var m = (reason && reason.message) ? String(reason.message) : String(reason || "");
    return /Failed to connect to MetaMask/i.test(m);
  }
  window.addEventListener("unhandledrejection", function (e) {
    if (!isNoise(e.reason)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, true);
  window.addEventListener("error", function (e) {
    if (!isNoise(e.error || e.message)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, true);
})();
        `}</Script>
        <IgnoreMetaMaskNoise />
        {children}
      </body>
    </html>
  );
}
