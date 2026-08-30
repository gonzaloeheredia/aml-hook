/**
 * Site footer: Virgilio wordmark, left-aligned.
 */
export function Footer() {
  return (
    <footer className="mt-auto border-t hair py-6 md:py-8">
      <img
        src="/virgilio-logo.png"
        alt="Virgilio"
        className="h-8 w-auto mix-blend-screen md:h-9 [html[data-theme=light]_&]:invert [html[data-theme=light]_&]:mix-blend-normal"
      />
    </footer>
  );
}
