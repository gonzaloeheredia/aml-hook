"use client";

/**
 * Route-level error UI so Next.js always has a recoverable error component.
 */
export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4 bg-black px-6 text-center text-white">
      <h2 className="text-2xl font-bold">Something went wrong</h2>
      <p className="max-w-md text-sm text-white/70">{error.message}</p>
      <button
        type="button"
        onClick={reset}
        className="rounded-full bg-[#FC72FF] px-5 py-2.5 text-sm font-semibold text-black"
      >
        Try again
      </button>
    </div>
  );
}
