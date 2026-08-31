"use client";

import { useEffect } from "react";

/**
 * A–D never call the injected wallet. Wallet E does (Sepolia swap).
 * MetaMask's `inpage.js` can still reject with "Failed to connect to MetaMask"
 * on A–D. Swallow only that extension noise so the simulated picker keeps working.
 */
export function IgnoreMetaMaskNoise() {
  useEffect(() => {
    const isMetaMaskNoise = (reason: unknown) => {
      const message =
        typeof reason === "string"
          ? reason
          : reason && typeof reason === "object" && "message" in reason
            ? String((reason as { message: unknown }).message)
            : String(reason ?? "");
      return /Failed to connect to MetaMask/i.test(message);
    };

    const onRejection = (event: PromiseRejectionEvent) => {
      if (!isMetaMaskNoise(event.reason)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    };

    const onError = (event: ErrorEvent) => {
      if (!isMetaMaskNoise(event.error ?? event.message)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    };

    window.addEventListener("unhandledrejection", onRejection, true);
    window.addEventListener("error", onError, true);
    return () => {
      window.removeEventListener("unhandledrejection", onRejection, true);
      window.removeEventListener("error", onError, true);
    };
  }, []);

  return null;
}
