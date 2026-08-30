import {
  DocHero,
  DocMeta,
  DocShell,
  DocStep,
  DocStory,
  DocTable,
} from "@/components/DocPage";

const STEPS = [
  {
    n: "0",
    title: "Clean swap",
    action:
      "Open hook. Connect Wallet D (or B / C). Swap $1,000 USDC → ETH.",
    rows: [
      { label: "Wallet", value: "D (or B / C)" },
      { label: "Score", value: "0, published" },
      { label: "Decision", value: "ALLOW" },
      { label: "Fee", value: "0.30%" },
    ],
    note: "D starts with 5,000 USDC and a published clean row. Size of already-held funds does not revert.",
  },
  {
    n: "1",
    title: "Exploit cash-out",
    action: "Connect Wallet A. Swap any size.",
    rows: [
      { label: "Score", value: "100" },
      { label: "Decision", value: "REVERT" },
      { label: "Error", value: "WalletBlocked · SCORE_REVERT_BAND" },
      { label: "Settlement", value: "None. Funds stay in A." },
    ],
    note: "A is not on OFAC. The officer wrote score 100 from an external exploit finding. A can still send USDC off-pool to B or C. Do not send A → E.",
  },
  {
    n: "2",
    title: "A sends to B",
    action:
      "Open MetaMask Simulator. Send USDC from A → B. Wait until the agent emits and the keeper publishes.",
    rows: [
      { label: "Hops from A", value: "1" },
      { label: "Agent score", value: "≈ 65" },
      { label: "Fee band", value: "8%" },
      { label: "On-chain write", value: "ComplianceOracle" },
    ],
  },
  {
    n: "3",
    title: "B swaps (1 hop)",
    action: "Connect B. Swap.",
    rows: [
      { label: "Score", value: "65" },
      { label: "Decision", value: "FEE_OVERRIDE" },
      { label: "Fee", value: "8%" },
      { label: "Escrow", value: "Differential above 0.30%" },
    ],
  },
  {
    n: "4",
    title: "B sends to C",
    action: "In MetaMask Simulator, send USDC from B → C. Wait for the keeper write.",
    rows: [
      { label: "Hops from A", value: "2" },
      { label: "Agent score", value: "≈ 42" },
      { label: "Fee band", value: "3%" },
      { label: "Closer hop wins", value: "A → C is still 1 hop / 65 / 8%" },
    ],
  },
  {
    n: "5",
    title: "C swaps (2 hops)",
    action: "Connect C. Swap.",
    rows: [
      { label: "Score", value: "42" },
      { label: "Decision", value: "FEE_OVERRIDE" },
      { label: "Fee", value: "3%" },
      { label: "Optional reverse", value: "Clean B after tainted C → 42 / 3%" },
    ],
  },
  {
    n: "6",
    title: "Floor C — 24-hour USD",
    action:
      "Restart data. Send 15,000 USDC from clean C → E. Connect E. Swap $10,000, then swap $5,000.",
    rows: [
      { label: "First E swap", value: "$10,000 → FEE_OVERRIDE 8%" },
      { label: "Second E swap", value: "$5,000 → REVERT" },
      { label: "Error", value: "DailyAggregationBlocked" },
      { label: "Rule", value: "Prior 24h + this swap ≥ $15,000" },
    ],
    note: "A first $15,000 ticket of the day is Floor A/B/D, not C. D works the same after two sized swaps that add to $15,000.",
  },
  {
    n: "7",
    title: "Floor B — stale score",
    action:
      "Stay on D (or any published-clean wallet that already swapped this hour). Press Advance 5 min. Swap again.",
    rows: [
      { label: "Score", value: "0, older than 5 minutes" },
      { label: "Decision", value: "FEE_OVERRIDE" },
      { label: "Floor", value: "STALE_WITH_POOL_ACTIVITY" },
      { label: "Fee", value: "3% on $1,000 (mid). Under $1,000 passes." },
    ],
    note: "B never reverts. $15,000 or more → 8%. A healthy keeper stamps updatedAt so a stable clean wallet does not look stale.",
  },
  {
    n: "8",
    title: "Clean inbound to D (mid)",
    action:
      "Restart so C and D are baseline. In MetaMask Simulator send 10,000 USDC from C → D. Connect D. Swap $1,000.",
    rows: [
      { label: "Oracle score", value: "0 (published, no hop)" },
      { label: "Inflow", value: "+$10,000 USD" },
      { label: "Decision", value: "FEE_OVERRIDE" },
      { label: "Fee", value: "3%" },
    ],
    note: "Do not use A here: A → D is a hop. Floor D: under $1,000 passes; $1,000–$14,999 → 3%; $15,000+ → 8%. D does not revert.",
  },
  {
    n: "9",
    title: "Clean inbound to D (large)",
    action:
      "Restart. Send 15,000 USDC from C → D (C still clean). Connect D. Swap any size.",
    rows: [
      { label: "Inbound USD", value: "15,000 since baseline" },
      { label: "Decision", value: "FEE_OVERRIDE" },
      { label: "Floor", value: "INFLOW_HEURISTIC" },
      { label: "Fee", value: "8%" },
    ],
    note: "Already-held clean funds never count as inbound. Only unknown-wallet Floor A blocks at $15,000.",
  },
  {
    n: "10",
    title: "Unknown wallet E",
    action:
      "E starts empty. Switch to C in MetaMask Simulator and send USDC to E. Then connect E and swap. Do not send A → E.",
    rows: [
      { label: "C→E $500, E swaps $500", value: "FEE_OVERRIDE 3%" },
      { label: "C→E $10k, E swaps $1,000", value: "FEE_OVERRIDE 8%" },
      { label: "C→E $15k, E swaps $15,000", value: "REVERT UnscoredMagnitudeBlocked" },
      { label: "Price feed", value: "Unbind after a prior quote → same floor, lastFx cache" },
    ],
    note: "Floor A looks at this swap. Floor D looks at the unpublished bag. The stricter fee wins. Restart between sizes so C’s 50,000 USDC covers each act.",
  },
  {
    n: "11",
    title: "Normative review",
    action:
      "Read why the cuts exist. No click in the demo — this is the officer / governor note.",
    rows: [
      { label: "$1,000 cut", value: "FATF VASP guidance 2021, note 37" },
      { label: "$15,000 cut", value: "FATF Rec. 10 occasional CDD" },
      { label: "24h window", value: "BSA CTR analogy (Floor C)" },
      { label: "Who retunes", value: "Officer proposes USD floors; governor retunes windows" },
    ],
  },
  {
    n: "12",
    title: "FeeEscrow",
    action:
      "After any FEE_OVERRIDE path, open Fees. The panel lists escrow rows. Publish a list hit or score ≥ 71, warp 48h → Checkpoint 2, warp 7d → Recover.",
    rows: [
      { label: "0–24h", value: "Optional review. Still in escrow." },
      { label: "24–48h clean", value: "Risk fee → LP fund. Principal → LP." },
      { label: "48h illicit", value: "ILLICIT_RISK_FEE / LP_PRINCIPAL" },
      { label: "Never to pool", value: "User output already settled in-block" },
    ],
  },
  {
    n: "13",
    title: "Opinion / COA file",
    action:
      "After a FEE_OVERRIDE or REVERT, open Opinion in hook. That screen is the Compliance Officer Agent file for this swap.",
    rows: [
      { label: "With Claude key", value: "Draft against the git corpus" },
      { label: "Without key", value: "Skill interpreter fills the same schema" },
      { label: "OFAC", value: "COA screens SDN; swap only reads the mapping" },
      { label: "Events", value: "Successful swaps emit SwapObserved" },
    ],
  },
] as const;

/**
 * Judge walkthrough, laid out like the Opinion module.
 */
export function UseOfCaseView() {
  return (
    <DocShell title="Use of case">
      <DocHero
        chip="Guided demo"
        heading="What to do in the hook"
        lede="Every decision below is the same mapping RiskPolicy.decide applies on-chain. Open hook, connect A–E, move USDC in MetaMask Simulator, then swap. Quotes cannot drift from the hook."
        asideTitle="Wallets"
        asideMark="A–E"
        meta={[
          { label: "A", value: "Exploit · score 100 · REVERT" },
          { label: "B / C", value: "Start clean · hop receivers" },
          { label: "D", value: "Published 0 · 5,000 USDC" },
          { label: "E", value: "Unknown · starts empty" },
        ]}
      />

      <div className="mt-12 grid gap-x-10 gap-y-8 md:grid-cols-2">
        <DocStory
          question="Where do I click?"
          answer="hook is the simulator. Connect opens A–E. MetaMask Simulator moves USDC off-pool and mints MockUSDC / MockWETH. Advance 5 min and Unbind price feed live on the swap card."
        />
        <DocStory
          question="What must already be running?"
          answer="From the repo root: npm run deploy:local, then the API and the frontend. Without Anvil the API returns 503. Hosted production talks to the Railway API."
        />
      </div>

      <div className="mt-16">
        <DocTable
          headers={["Step", "Actor", "Action", "Result"]}
          rows={[
            ["0", "D / B / C", "Swap held USDC", "ALLOW · 0.30%"],
            ["1", "A", "Pool cash-out", "REVERT · WalletBlocked"],
            ["2", "A → B", "P2P in MetaMask", "Score ≈ 65 published"],
            ["3", "B", "Swap", "FEE_OVERRIDE · 8%"],
            ["4", "B → C", "P2P", "Score ≈ 42 published"],
            ["5", "C", "Swap", "FEE_OVERRIDE · 3%"],
            ["6", "E or D", "$10k then $5k in 24h", "REVERT · Floor C"],
            ["7", "D", "Advance 5 min, swap", "FEE_OVERRIDE · Floor B"],
            ["8–9", "C → D", "Clean inbound, then swap", "3% / 8% Floor D"],
            ["10", "C → E", "Fund unknown, then swap", "A / D bands or REVERT"],
            ["11–13", "Officer", "Floors, escrow, Opinion", "Review · recover · file"],
          ]}
        />
      </div>

      <div className="mt-24 border-t hair pt-16 md:mt-28 md:pt-20">
        <p className="text-center text-[12px] font-medium tracking-[0.16em] text-uni-muted">
          Walkthrough
        </p>
        <h2 className="mt-3 text-center font-serif text-[32px] font-normal tracking-tight text-uni-pink md:text-[40px]">
          Step by step
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-center text-[15px] leading-relaxed text-uni-muted">
          Run these in order. Restart data when a step says so, so balances and
          scores return to baseline.
        </p>

        <div className="mt-16 space-y-14 md:mt-20">
          {STEPS.map((step) => (
            <DocStep
              key={step.n}
              n={step.n}
              title={step.title}
              action={step.action}
              rows={[...step.rows]}
              note={"note" in step ? step.note : undefined}
            />
          ))}
        </div>
      </div>

      <aside className="radius-g mt-16 border-t hair px-1 py-6 md:px-2">
        <div className="grid gap-6 sm:grid-cols-2">
          <DocMeta label="N-hop formula" value="score = 100 × 0.65^hops" />
          <DocMeta label="1 hop / 2 hops" value="≈ 65 / 8% · ≈ 42 / 3%" />
          <DocMeta
            label="Sanctions"
            value="Named-address OFAC is hook functionality, not a demo wallet"
          />
          <DocMeta
            label="Local quotes"
            value="MockUsdFeed · $1 USDC · $1,000 ETH"
          />
        </div>
      </aside>
    </DocShell>
  );
}
