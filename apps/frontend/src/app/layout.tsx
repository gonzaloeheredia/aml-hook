import type { Metadata } from "next";
import Script from "next/script";
import { Plus_Jakarta_Sans } from "next/font/google";
import { IgnoreMetaMaskNoise } from "@/components/IgnoreMetaMaskNoise";
import "./globals.css";

/**
 * Primary UI font — distinctive sans used across the Uniswap-styled demo.
 */
const jakarta = Plus_Jakarta_Sans({
  variable: "--font-jakarta",
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
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
    <html lang="en">
      <body className={`${jakarta.variable} font-sans antialiased bg-uni-bg text-white`}>
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
