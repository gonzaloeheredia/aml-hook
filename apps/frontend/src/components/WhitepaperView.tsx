import {
  DocHero,
  DocRow,
  DocShell,
  DocStory,
  DocTable,
} from "@/components/DocPage";

/**
 * Product whitepaper, laid out like the Opinion module.
 */
export function WhitepaperView() {
  return (
    <DocShell title="Whitepaper">
      <DocHero
        chip="Product paper"
        heading="AML Hook"
        lede="Modular compliance layer for Uniswap v4. Institutions stay out of DeFi when they cannot tell clean liquidity from tainted liquidity. AML Hook is the layer that lets them participate with regulatory certainty."
        asideTitle="Document"
        asideMark="AH"
        meta={[
          { label: "Author", value: "Gonzalo Emanuel Heredia" },
          { label: "Layer", value: "Uniswap v4 hook" },
          { label: "Outputs", value: "ALLOW · FEE_OVERRIDE · REVERT" },
        ]}
      />

      <div className="mt-12 grid gap-x-10 gap-y-8 md:grid-cols-2">
        <DocStory
          question="What is missing today?"
          answer="About USD 25 billion in RWAs already sit on-chain without circulating. Identity checks at the door are a start. They have no memory of what the wallet does next."
        />
        <DocStory
          question="What does the hook do?"
          answer="It runs on every swap. It keeps a behavioral history per wallet and returns one of three outcomes: allow, allow with an extra fee held for review, or revert."
        />
        <DocStory
          question="How is it different?"
          answer="Permissioned Pools is the door: who may enter. AML Hook is the film after the door: how those addresses behave once they are in. The two products stack."
        />
        <DocStory
          question="Where is the revenue?"
          answer="The extra fee on an atypical-but-not-confirmed-illicit swap is residual risk the pool would otherwise absorb for free. That differential is a new line."
        />
      </div>

      <article className="mx-auto mt-16 max-w-[720px] pb-8">
        <p className="text-center text-[12px] font-medium tracking-[0.16em] text-uni-muted">
          Modular Compliance Layer for Uniswap v4
        </p>
        <h3 className="mt-3 text-center font-serif text-[32px] font-normal tracking-tight text-uni-pink md:text-[40px]">
          The product
        </h3>

        <div className="mt-10 space-y-6 text-[16px] font-normal leading-[1.85] text-uni-pink/85">
          <p>
            DeFi does not know who operates in its pools or how they behaved
            before. Any address can swap with any other, and nobody records
            what happened or why. In traditional finance, reputation builds
            over time. In DeFi every wallet starts from zero on every swap.
          </p>
          <p>
            For retail this is a nuisance. For institutions it is a blocker. A
            regulated fund, a market maker, or a European protocol under MiCA
            cannot operate where it cannot show that counterparties meet due
            diligence.
          </p>
        </div>

        <div className="mt-12 space-y-8">
          <DocRow
            label="The crime model"
            value="Operators buy time (lists lag), distance (mule hops), smallness (structuring under a threshold), and borrowed reputation (a clean wallet with a sudden inbound). A static list or KYC pass does not see those."
          />
          <DocRow
            label="What the hook intercepts"
            value="On swaps: beforeSwap and afterSwap. It screens the resolved end-user, reads a behavioral score, and decides. Independently it also intercepts liquidity add and remove. Pause stops swap evaluation; it does not freeze a clean LP mint or exit."
          />
        </div>

        <h4 className="mt-16 font-serif text-[22px] font-normal tracking-tight text-uni-pink">
          Three outputs
        </h4>
        <div className="mt-6">
          <DocTable
            headers={["Score", "Output", "Why"]}
            rows={[
              [
                "0–30",
                "Allow at the standard fee",
                "No sanctioned exposure, no anomalous pattern.",
              ],
              [
                "31–54",
                "Fee-override at 3%",
                "Atypical behavior without a confirmed sanction.",
              ],
              [
                "55–70",
                "Fee-override at 8%",
                "Same band family; keeper may send an explicit fee.",
              ],
              [
                "71–100 or OFAC",
                "Revert",
                "Confirmed exposure. No discretion.",
              ],
            ]}
          />
        </div>

        <h4 className="mt-16 font-serif text-[22px] font-normal tracking-tight text-uni-pink">
          Four layers
        </h4>
        <div className="mt-6">
          <DocTable
            headers={["Layer", "Name", "Function"]}
            rows={[
              [
                "1",
                "Static sanctions",
                "OFAC or another list. Match → immediate block. No external call at execution.",
              ],
              [
                "2",
                "Behavioral score",
                "Off-chain engine. The score is pre-computed. The hook only reads it.",
              ],
              [
                "3",
                "Decision",
                "RiskPolicyLib / LpPolicyLib map layers 1–2 plus latency floors to allow, extra fee, or revert.",
              ],
              [
                "4",
                "Profile update",
                "After the swap, emit what happened so the engine can update the wallet before the next one.",
              ],
            ]}
          />
        </div>

        <h4 className="mt-16 font-serif text-[22px] font-normal tracking-tight text-uni-pink">
          Swap lifecycle
        </h4>
        <div className="mt-6">
          <DocTable
            headers={["Moment", "Action"]}
            rows={[
              [
                "Before the swap",
                "Resolve the end-user. Run sanctions, read the score, decide. A revert cancels the swap before funds move.",
              ],
              [
                "After the swap",
                "Update local activity. Emit the audit event. On fee-override, take only the extra risk slice into FeeEscrow.",
              ],
            ]}
          />
        </div>

        <div className="mt-12 space-y-8">
          <DocRow
            label="Legal baseline"
            value="OFAC / SDN at Layer 1. FATF Rec. 15 if the operator has a point of control. MiCA for European VASPs — a UI block is easy to bypass; the hook is inside the pool. SEC / CFTC audit trail. GENIUS Act compatibility for reserved payment-stablecoins. FATF / FinCEN monitoring with a record of actions taken."
          />
          <DocRow
            label="Permissioned Pools"
            value="Labs’ product is the door: who may hold exposure. It does not score behavior or calibrate a fee. AML Hook is the film after the door. The permissioned router is the shared entry."
          />
          <DocRow
            label="Market"
            value="TAM: tokenized RWA (~USD 100B by end-2026). SAM: mid-market private credit. First pools: Centrifuge, Goldfinch, Clearpool and peers that need a compliance difference versus Maple-scale institutional guarantees."
          />
          <DocRow
            label="Compliance Officer Agent"
            value="The hook number is the on-chain decision. The agent writes the file the operator keeps: why this swap was allowed, charged, or reverted. beforeSwap never calls the model — it reads the oracle row the keeper published."
          />
        </div>

        <h4 className="mt-16 font-serif text-[22px] font-normal tracking-tight text-uni-pink">
          Competitive map
        </h4>
        <div className="mt-6">
          <DocTable
            headers={["Product", "When", "Memory", "Dynamic fee"]}
            rows={[
              ["PureFi", "Before swap", "No", "No"],
              ["Predicate / USDL", "Before swap", "No", "No"],
              ["Coinbase Verified", "Before swap", "No", "No"],
              ["Civic / Violet", "Before swap", "No", "No"],
              ["Levery", "Before swap", "No", "No"],
              ["Permissioned Pools", "Before swap", "No", "Yes (access)"],
              ["AML Hook", "Before and after", "Yes", "Yes"],
            ]}
          />
        </div>

        <details className="group mt-14 border-t hair pt-6">
          <summary className="cursor-pointer list-none text-center text-[13px] text-uni-muted transition hover:text-uni-pink [&::-webkit-details-marker]:hidden">
            Technical appendix
            <span className="ml-1.5 group-open:hidden">
              · floors, escrow, architecture
            </span>
          </summary>
          <div className="mt-8 space-y-8">
            <DocRow
              label="Architecture"
              value="Uniswap v4 puts every pool in one PoolManager. The pool key carries the hook address. Full evaluation plus governance does not fit EIP-170, so AmlHook DELEGATECALLs a logic contract that shares one state."
            />
            <DocRow
              label="Fee escrow"
              value="On FEE_OVERRIDE the pool keeps 0.30%. The extra slice sits in FeeEscrow. Clean release goes to the LP compensation fund. Confirmed illicit recover goes to ComplianceTreasury — never back to the pool, never to LPs while still suspect."
            />
            <DocRow
              label="Latency floors"
              value="When the keeper has not written, the score is stale, or a large inflow is still unpublished, score bands are not enough. Floors A–D cover unknown wallets, stale scores, 24h USD aggregation, and inbound USD on a published-clean wallet. Full numeric table is in whitepaper §8.4 and in Use of case."
            />
          </div>
        </details>
      </article>
    </DocShell>
  );
}
