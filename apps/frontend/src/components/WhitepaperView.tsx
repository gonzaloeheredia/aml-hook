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
        lede="Modular compliance layer for Uniswap v4. Institutions stay out of DeFi (decentralized finance) when they cannot tell clean liquidity from tainted liquidity. AML Hook is the layer that lets them participate with regulatory certainty."
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
          answer="About USD 25 billion in RWAs (Real World Assets) already sit on-chain without circulating. Identity checks at entry are a start. They have no memory of what the wallet does next."
        />
        <DocStory
          question="What does the hook do?"
          answer="It runs on every swap. It keeps a behavioral history per wallet and returns one of three outcomes: allow, allow with an extra fee held for review, or revert."
        />
        <DocStory
          question="How is it different?"
          answer="Permissioned Pools governs who may enter. AML Hook evaluates how those addresses behave once they hold that access. The two products stack."
        />
        <DocStory
          question="Where is the revenue?"
          answer="The extra fee on an atypical swap that still lacks a confirmed illicit finding is residual risk the pool would otherwise absorb for free. That differential is a new revenue line."
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
            DeFi leaves unknown both who operates in its pools and how those
            addresses behaved before. Any address can swap with any other, and
            nobody records what happened or why. In traditional finance,
            reputation builds over time. In DeFi every wallet starts from zero
            on every swap.
          </p>
          <p>
            Retail users absorb that gap as inconvenience. For institutions it
            blocks participation. A regulated fund, a market maker, or a
            European protocol under MiCA (Markets in Crypto-Assets Regulation)
            cannot operate where it cannot show that counterparties meet due
            diligence.
          </p>
        </div>

        <div className="mt-12 space-y-8">
          <DocRow
            label="The crime model"
            value="Illicit operators optimize for time (lists lag), distance (mule hops), smallness (structuring under a threshold), and borrowed reputation (a clean wallet with a sudden inbound transfer). A static list or a one-time KYC (Know Your Customer) check leaves those patterns unseen."
          />
          <DocRow
            label="What the hook intercepts"
            value="On swaps, the hook runs before and after execution. It screens the resolved end user, reads a behavioral score, and decides. Liquidity add and remove run on a separate path. Pausing the hook stops swap evaluation only; a clean liquidity provider can still mint or exit."
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
                "0 to 30",
                "Allow at the standard fee",
                "No sanctioned exposure, no anomalous pattern",
              ],
              [
                "31 to 54",
                "Fee override at 3%",
                "Atypical behavior without a confirmed sanction",
              ],
              [
                "55 to 70",
                "Fee override at 8%",
                "Same band family, closer to a confirmed pattern",
              ],
              [
                "71 to 100, or a sanctions match",
                "Revert",
                "Confirmed exposure. No discretion",
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
                "Sanctions screening",
                "Checks the resolved address against OFAC (Office of Foreign Assets Control) and equivalent lists. A match reverts the swap in that transaction. No external call at execution",
              ],
              [
                "2",
                "Behavioral scoring",
                "An off-chain engine assigns a risk score based on transfer history. The score is computed ahead of time; the hook only reads it",
              ],
              [
                "3",
                "Decision",
                "Combines the sanctions result, the score, and timing checks into one outcome: allow, extra fee, or revert",
              ],
              [
                "4",
                "Profile update",
                "After the swap, the hook records what happened so the engine can update the wallet's history before its next swap",
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
                "Resolve the end user, run the sanctions check, read the score, decide. A revert cancels the swap before funds move",
              ],
              [
                "After the swap",
                "Update the wallet's history, record the audit event. On a fee override, only the extra risk portion is set aside in escrow (held in a dedicated contract pending review), not the full fee",
              ],
            ]}
          />
        </div>

        <h4 className="mt-16 font-serif text-[22px] font-normal tracking-tight text-uni-pink">
          Legal baseline
        </h4>
        <div className="mt-6">
          <DocTable
            headers={["Framework", "What it requires"]}
            rows={[
              [
                "OFAC / SDN (Specially Designated Nationals)",
                "Screening at Layer 1",
              ],
              [
                "FATF (Financial Action Task Force) Recommendation 15",
                "Applies where the operator has a point of control",
              ],
              [
                "MiCA (Markets in Crypto-Assets Regulation)",
                "A front-end block is easy to bypass; enforcement inside the pool is not",
              ],
              [
                "SEC (Securities and Exchange Commission) / CFTC (Commodity Futures Trading Commission)",
                "An audit trail of decisions taken",
              ],
              [
                "GENIUS Act",
                "Compatibility for reserved payment stablecoins",
              ],
              [
                "FATF / FinCEN (Financial Crimes Enforcement Network)",
                "Ongoing monitoring with a record of actions taken",
              ],
            ]}
          />
        </div>

        <div className="mt-12 space-y-8">
          <DocRow
            label="Permissioned Pools"
            value="Uniswap Labs' Permissioned Pools governs who may hold exposure to a pool. It leaves behavior unscored and the fee uncalibrated once access is granted. AML Hook evaluates conduct after access is already in place. The permissioned router is the shared entry point for both."
          />
          <DocRow
            label="Market"
            value="TAM (Total Addressable Market): tokenized RWA, about USD 100 billion by end of 2026. SAM (Serviceable Addressable Market): mid-market private credit. First target pools: Centrifuge, Goldfinch, Clearpool, and peers that need a compliance difference versus Maple-scale institutional guarantees."
          />
          <DocRow
            label="Compliance Officer Agent"
            value="The hook's on-chain output is the decision itself. The agent writes the file a compliance operator keeps: why a given swap was allowed, charged, or reverted. The hook reads the score the agent already published; it never calls the agent directly during a swap."
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
              ["Permissioned Pools", "Before swap", "No", "Yes (access only)"],
              ["AML Hook", "Before and after", "Yes", "Yes"],
            ]}
          />
        </div>

        <details className="group mt-16">
          <summary className="radius-a surface cursor-pointer list-none border-l-[1.5px] border-[#FC72FF] px-[22px] py-[22px] md:px-8 md:py-7 [&::-webkit-details-marker]:hidden">
            <p className="text-[15px] font-normal leading-relaxed text-uni-muted">
              This page is a summary. Contract names, fee formulas, and floor
              definitions live in the technical appendix.
            </p>
            <span className="mt-4 inline-block text-[13px] font-medium text-[#FC72FF] transition group-hover:brightness-110">
              <span className="group-open:hidden">Open technical appendix</span>
              <span className="hidden group-open:inline">
                Close technical appendix
              </span>
            </span>
          </summary>
          <div className="mt-8 space-y-8">
            <DocRow
              label="Architecture"
              value="Uniswap v4 puts every pool in one PoolManager. The pool key carries the hook address. Full evaluation plus governance exceeds the EIP-170 size cap, so AmlHook DELEGATECALLs a logic contract that shares one state."
            />
            <DocRow
              label="Fee escrow"
              value="On FEE_OVERRIDE the pool keeps 0.30%. The extra slice sits in FeeEscrow. Clean release goes to LpCompensationVault (LPs claim after epoch close). Confirmed illicit recover goes to ComplianceTreasury, then a delayed allowlisted payout. The slice never returns to the pool, and never to LPs while still suspect."
            />
            <DocRow
              label="Latency floors"
              value="When the keeper has not written, the score is stale, or a large inflow is still unpublished, score bands leave those cases uncovered. Floors A–D cover unknown wallets, stale scores, 24h USD aggregation, and inbound USD on a published-clean wallet. Full numeric table is in whitepaper §8.4 and in Use of case."
            />
          </div>
        </details>
      </article>
    </DocShell>
  );
}
