import type { Metadata } from "next";
import { Plus_Jakarta_Sans } from "next/font/google";
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
        {children}
      </body>
    </html>
  );
}
