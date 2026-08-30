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
    explain:
      "D already holds this money and it's already scored clean. Nothing new to flag, so the swap goes through at the pool's normal fee.",
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
    explain:
      "A's score of 100 blocks any pool swap outright — the funds never move, they just stay in A. A can still move funds off-pool; only swaps are blocked.",
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
    explain:
      "This transfer is what carries the risk forward. An off-chain engine sees it and scores B as 1 hop from A (~65); the keeper publishes that score on-chain.",
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
    explain:
      "A score of 55-70 doesn't block the swap, but charges a steep 8% fee as a penalty for being close to the tainted source. The extra fee goes to escrow, not lost.",
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
    explain:
      "Same mechanism, one hop further. Two hops from A dilutes the score to ~42. A closer hop always wins over a farther one if both exist.",
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
    explain:
      "Same idea as Step 3, but the lower score falls in the cheaper FEE_OVERRIDE band: 3% instead of 8%. Farther from the tainted source, smaller penalty.",
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
    explain:
      "The C → E transfer never touches the hook — it is a plain ERC-20 transfer, not a swap, so no floor applies to it. Floor C only accumulates E's own swap volume against the pool: $10,000 + $5,000 = $15,000 crosses the threshold. The revert is on E's cumulative swaps, not on the incoming transfer.",
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
    explain:
      "This isn't about D doing anything suspicious — it tests what happens when the score-writer goes quiet. D's score is still 0, just not refreshed in over 5 minutes, so the hook charges a small precautionary fee instead of trusting a possibly-stale row. This floor never blocks, only charges more.",
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
    explain:
      "D is already published clean (score 0). C's transfer never touches the hook — it's a plain wallet-to-wallet transfer. That new money just hasn't been assessed yet. When D swaps, the hook checks for unassessed inbound funds: mid-size inflow (Step 8) costs 3% extra, large inflow (Step 9) costs 8% extra. D never reverts here — a clean source paying more while new money settles is not the same as an unscored wallet being blocked (Floor A).",
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
    explain:
      "D is already published clean (score 0). C's transfer never touches the hook — it's a plain wallet-to-wallet transfer. That new money just hasn't been assessed yet. When D swaps, the hook checks for unassessed inbound funds: mid-size inflow (Step 8) costs 3% extra, large inflow (Step 9) costs 8% extra. D never reverts here — a clean source paying more while new money settles is not the same as an unscored wallet being blocked (Floor A).",
  },
  {
    n: "10",
    title: "E - New Wallet",
    action:
      "E starts empty. Fund E from clean C (P2P) or mint 1,000 USDC + 1 ETH to E. Then connect E and swap. Do not send A → E.",
    rows: [
      { label: "C→E $500, E swaps $500", value: "FEE_OVERRIDE 3%" },
      { label: "C→E $10k or mint $1k, E swaps $1,000", value: "FEE_OVERRIDE 8%" },
      { label: "C→E $15k, E swaps $15,000", value: "REVERT UnscoredMagnitudeBlocked" },
      { label: "Price feed", value: "POST /demo/price-feed after a prior quote → lastFx cache" },
    ],
    note: "Floor A looks at this swap. Floor D looks at the unpublished bag. The stricter fee wins. Restart between sizes so C’s 50,000 USDC covers each act.",
    explain:
      "E can be funded two ways. C → E is a plain ERC-20 transfer; a faucet mint writes tokens straight to E. Neither path touches the hook. Floor A/D compares E's current balance to a stored baseline, so a mint and a C → E transfer of the same size have the same effect. Use C → E for the $500 / $10,000 / $15,000 sizes: the mint (panel and faucet) is a fixed 1,000 MockUSDC + 1 MockWETH. Fund from C, not A — A → E would be a hop, not an unknown-wallet test.",
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
    explain:
      "No demo action here — this is why these numbers exist. $1,000 comes from FATF guidance on virtual assets; $15,000 from FATF Recommendation 10; the 24-hour window echoes the US BSA's CTR concept. The compliance officer proposes dollar floors; the hook governor tunes time windows.",
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
    explain:
      "The extra fee from any FEE_OVERRIDE swap doesn't go straight to LPs — it sits in escrow for 24-48 hours. If nothing bad is confirmed, it releases to LPs or back to principal. If the wallet is later confirmed sanctioned or high-risk, it moves to the compliance treasury instead. The swap itself already settled; only this extra fee waits.",
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
    explain:
      "After any FEE_OVERRIDE or REVERT, an Opinion documents why. With a Claude key configured, an AI model drafts it against real regulatory sources; without one, a simpler rule-based fallback fills the same structure. This screen also checks the wallet against the official OFAC sanctions list and records any match on-chain.",
  },
] as const;

/**
 * Guided walkthrough, laid out like the Opinion module.
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
          { label: "E", value: "New Wallet · starts empty" },
        ]}
      />

      <div className="mt-12 grid gap-x-10 gap-y-8 md:grid-cols-2">
        <DocStory
          question="Where do I click?"
          answer="hook is the simulator. Connect opens A–E. MetaMask Simulator moves USDC off-pool and mints 1,000 MockUSDC or 1 MockWETH to the open account. Advance 5 min is on the swap card. Unbind the price feed is POST /demo/price-feed."
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
            ["10", "C → E or mint", "Fund unknown, then swap", "A / D bands or REVERT"],
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
              explain={"explain" in step ? step.explain : undefined}
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
