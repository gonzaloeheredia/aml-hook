"use client";

/**
 * Root error boundary required by the App Router when the root layout fails.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <html lang="en">
      <body style={{ background: "#000", color: "#fff", fontFamily: "sans-serif" }}>
        <div
          style={{
            minHeight: "100vh",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            gap: 16,
            padding: 24,
            textAlign: "center",
          }}
        >
          <h2 style={{ fontSize: 24, fontWeight: 700 }}>Something went wrong</h2>
          <p style={{ opacity: 0.7, maxWidth: 420 }}>{error.message}</p>
          <button
            type="button"
            onClick={reset}
            style={{
              background: "transparent",
              color: "#E8E4D9",
              border: "1px solid rgba(232, 228, 217, 0.45)",
              borderRadius: 0,
              padding: "10px 20px",
              fontWeight: 500,
              cursor: "pointer",
            }}
          >
            Try again
          </button>
        </div>
      </body>
    </html>
  );
}
