import type { ReactNode } from "react";
import { DocBackToTop } from "@/components/DocBackToTop";

const ACCENT = "#FC72FF";

type ShellProps = {
  title: string;
  children: ReactNode;
};

/**
 * Document chrome shared by Whitepaper and Use of case:
 * same centered serif title and max-width as LegalOpinion.
 */
export function DocShell({ title, children }: ShellProps) {
  return (
    <section id="doc-module" className="relative pb-16 pt-8 md:pt-12">
      <div className="mb-20 text-center md:mb-28">
        <h1 className="font-serif text-balance text-4xl font-normal tracking-tight md:text-5xl">
          {title}
        </h1>
      </div>
      <div className="relative mx-auto w-full max-w-[1000px] px-2 pb-8 sm:px-3 md:-translate-x-3">
        {children}
      </div>
      <DocBackToTop />
    </section>
  );
}

type HeroProps = {
  chip: string;
  heading: string;
  lede: string;
  asideTitle: string;
  asideMark: string;
  meta: { label: string; value: string }[];
};

export function DocHero({
  chip,
  heading,
  lede,
  asideTitle,
  asideMark,
  meta,
}: HeroProps) {
  return (
    <div className="grid items-start gap-8 md:grid-cols-[minmax(0,1.5fr)_minmax(0,0.72fr)] md:gap-14">
      <div
        className="radius-a surface border-l-[1.5px] px-[22px] py-[22px] md:px-8 md:py-7"
        style={{ borderColor: ACCENT }}
      >
        <div className="text-[13px] font-medium" style={{ color: ACCENT }}>
          {chip}
        </div>
        <h2 className="mt-[10px] font-serif text-balance text-[26px] font-normal leading-tight tracking-tight text-uni-pink md:text-[28px]">
          {heading}
        </h2>
        <p className="mt-[10px] max-w-xl text-[15px] font-normal leading-relaxed text-uni-muted">
          {lede}
        </p>
      </div>
      <aside className="radius-d border-t hair px-1 py-5 md:mt-10">
        <div className="mb-[22px] flex items-center gap-[10px]">
          <span
            className="flex h-[34px] w-[34px] items-center justify-center text-[13px] font-medium"
            style={{
              background: "rgb(var(--ink))",
              color: "rgb(var(--background))",
              borderRadius: "14px 2px 10px 2px",
            }}
            aria-hidden
          >
            {asideMark}
          </span>
          <span className="label-kicker">{asideTitle}</span>
        </div>
        <div className="flex flex-col gap-[22px]">
          {meta.map((row) => (
            <DocMeta key={row.label} label={row.label} value={row.value} />
          ))}
        </div>
      </aside>
    </div>
  );
}

export function DocMeta({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="label-kicker">{label}</div>
      <div className="mt-1.5 font-serif text-[17px] font-normal leading-snug text-uni-pink">
        {value}
      </div>
    </div>
  );
}

export function DocStory({
  question,
  answer,
}: {
  question: string;
  answer: string;
}) {
  return (
    <div>
      <h3 className="font-serif text-[18px] text-uni-pink">{question}</h3>
      <p className="mt-[10px] text-[15px] font-normal leading-relaxed text-uni-muted">
        {answer}
      </p>
    </div>
  );
}

export function DocRow({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="font-serif text-[17px] text-uni-pink">{label}</div>
      <p className="mt-2 text-[15px] font-normal leading-relaxed text-uni-muted">
        {value}
      </p>
    </div>
  );
}

export function DocTable({
  headers,
  rows,
}: {
  headers: string[];
  rows: string[][];
}) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[520px] border-collapse text-left">
        <thead>
          <tr className="border-b hair">
            {headers.map((h) => (
              <th
                key={h}
                className="label-kicker pb-3 pr-4 font-medium first:pl-0"
              >
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={i} className="border-b hair align-top last:border-b-0">
              {row.map((cell, j) => (
                <td
                  key={`${i}-${j}`}
                  className={`py-3 pr-4 text-[14px] leading-relaxed ${
                    j === 0 ? "font-serif text-uni-pink" : "text-uni-muted"
                  }`}
                >
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

type StepProps = {
  n: string;
  title: string;
  action: string;
  rows?: { label: string; value: string }[];
  note?: string;
  explain?: string;
};

export function DocStep({ n, title, action, rows, note, explain }: StepProps) {
  return (
    <article className="border-t hair pt-10">
      <div className="label-kicker">Step {n}</div>
      <h3 className="mt-3 font-serif text-[26px] font-normal tracking-tight text-uni-pink md:text-[28px]">
        {title}
      </h3>
      <p className="mt-4 max-w-2xl text-[16px] font-normal leading-[1.85] text-uni-pink/85">
        {action}
      </p>
      {rows && rows.length > 0 ? (
        <div className="mt-8 grid gap-6 sm:grid-cols-2">
          {rows.map((row) => (
            <DocMeta key={row.label} label={row.label} value={row.value} />
          ))}
        </div>
      ) : null}
      {note || explain ? (
        <div className="mt-6 space-y-3">
          {note ? (
            <p className="text-[15px] font-normal leading-relaxed text-uni-muted">
              {note}
            </p>
          ) : null}
          {explain ? (
            <p className="text-[15px] font-normal leading-relaxed text-uni-muted">
              {explain}
            </p>
          ) : null}
        </div>
      ) : null}
    </article>
  );
}
