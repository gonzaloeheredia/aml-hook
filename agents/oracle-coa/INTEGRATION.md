# Oracle COA — integration in aml-hook (demo)

This folder is the Compliance Officer Agent package (prompts + skills) used as
the **off-chain scoring oracle** for the UHI10 demo.

## Runtime

The TypeScript runner lives in `apps/api/src/oracle/`. With `ANTHROPIC_API_KEY`,
Claude emits score, fee, and Opinion (`liveScore.ts`). Tools:
`consult_skill` (call `uhi10-use-case` before scoring A–F),
`search_regulations`, `get_active_version_at`, `screen_ofac`. The keeper publishes
`finalScore` + `recommendedFeeBps` to `ComplianceOracle`. Quotes use
`AmlHook.previewSwap`. A 3-minute tick stamps `updatedAt` without calling
Claude. Without a key, `COA_LIVE=0`, or `npm test`, `factScoring.ts`
interprets the skills. Every evaluation (and every Opinion) screens the
subject against the live OFAC SDN ETH list and writes `SanctionRegistry`
on an exact match. The swap still only reads that mapping.

| Module | Role |
|---|---|
| `agent.ts` | Skill flow FULL / INCREMENTAL + publish |
| `liveScore.ts` | Claude score + fee + Opinion |
| `liveOpinion.ts` | Anthropic loop + corpus / skill tools |
| `keeper.ts` | Heartbeat `updateScore` (no Claude) |
| `skills.ts` | Load `agents/oracle-coa/skills/*.md` |
| `factScoring.ts` | Interpreter for tests / no key |
| `report.ts` | Opinion schema (`task-regulatory-report`) |
| `corpus.ts` | `searchRegulations` · `getActiveVersionAt` |
| `store.ts` | In-memory cache. Quotes do not read this |
| `onchainPublisher.ts` | Keeper → `ComplianceOracle.updateScore` (signed RPC, or fail). The attestor must sign `attestationHash(wallet, score, hopDistance, origin, feeBps, updatedAt, chainid)`. A score-only or empty signature is rejected. |
| `ofacSdn.ts` / `ofacScreen.ts` | Live OFAC SDN ETH set + `setSanctioned` writer |
| `types.ts` | `ScoreResult` · `OracleOpinion` · `ScorePublishResult` |

No live OpenSanctions / Etherscan / Chainalysis calls. Facts come from Anvil
wallets, P2P ERC-20 transfers, `SwapObserved` / `WalletBlocked`, live OFAC SDN
(ETH addresses), and `SanctionRegistry`. N-hop decay (`100 × 0.65^hops`) is the A–F backbone in
skill `uhi10-use-case`; the agent applies it — TypeScript does not precompute
65/42 when live.

## FEE_OVERRIDE vs FeeEscrow (aligned with contracts)

| Moment | What happens |
|---|---|
| `afterSwap` on `FEE_OVERRIDE` | Hook takes differential (`feeBps − 30`) → `FeeEscrow.deposit` (`RiskFee`) |
| `afterAddLiquidity` on 31–70 / never-scored 3%/8% | Hook takes the **full** override → `FeeEscrow.deposit` (`RiskFee`) |
| Blocked LP remove | Principal → `LpPrincipal`; `feesAccrued` → `RiskFee`. Both 48h. |
| FeeEscrow keeper | Checkpoint 1/2 / default after COA off-chain review (COA never writes escrow) |
| Clean Checkpoint 2 | Risk fee → LP compensation fund. Principal → LP wallet. |
| Illicit recover | `ILLICIT_RISK_FEE` vs `LP_PRINCIPAL` by kind |

| Layer | Behavior |
|---|---|
| COA / oracle | Publishes `finalScore` + `recommendedFeeBps` (total friction, e.g. 800 / 300) |
| `beforeSwap` | Ternary decision; does **not** set punitive `lpFeeOverride` — pool keeps standard fee |

Opinion copy must describe **standard pool fee + escrowed differential**, not
`lpFeeOverride` as the settlement path.

## Triggers

```
POST /transfers  → wait for agent → reevaluate(from) + reevaluate(to)
                 → exception: to=D defers keeper (stale score 0 for inflow demo)
POST /swaps      → afterSwap SwapObserved → wait for agent → reevaluate(wallet)
                 → or WalletBlocked → wait for agent → reevaluate(wallet)
                 → if D keeperPending: catch-up publish (~65) after latency swap
POST /oracle/:id/catch-up → manual deferred publish (Wallet D)
POST /reset      → clear + seed oracle for A–D and F (Claude wait when key set; E unpublished)
keeper tick 3m   → republish last agent score (no Claude). If the agent is down, this stamp still keeps Floor B (5 min) quiet.
```

Quotes and swaps call `AmlHook.previewSwap` (same L1→L3 as `beforeSwap`). They
do not apply TypeScript floors on the COA cache. The keeper writes when the
decision tier or fee band changes, **or** on a 3-minute heartbeat (same score,
new `updatedAt`), **or** when the last write is at least as old as Floor B
(5 minutes). The publisher is signed RPC or it fails.
That freshness stamp stops a stable clean wallet from looking stale. Floor B
charges 3% on the first stale swap of the hour, then pass / 3% / 8% by swap+window
USD if the keeper is late and the wallet already swapped in that hour.
A wallet with `updatedAt == 0` is Mitigation A
(unknown / Wallet E): the hook converts **this swap** to USD-8 (`lastFx` if
younger than 30 minutes, else Chainlink; official ETH/USD + USDC/USD on a live Deploy; `MockUsdFeed` on Anvil), then
Floor D on the unpublished bag. The stricter fee wins. Demo E starts empty;
clean C funds it (no hop). After C→E $500 a $500 swap is 3%. After C→E
$10,000 a $1,000 swap is 8% (A mid). After C→E $15,000 a small swap is 8%.
Floor C may still REVERT if prior 24h USD + this swap crosses $15,000.

| Assessed USD-8 | Hook output |
|---|---|
| < `unscoredFeeThreshold` (default $1,000 / `1_000e8`) | `FEE_OVERRIDE` 3% |
| $1,000 – $14,999 | `FEE_OVERRIDE` 8% |
| ≥ `unscoredRevertThreshold` (default $15,000 / `15_000e8`) this swap | `UnscoredMagnitudeBlocked` |
| Prior 24h USD > 0 and prior + this swap ≥ $15,000 | `DailyAggregationBlocked` (Floor C) |
| No live round and no `lastFx` within 24h | `MagnitudeQuoteFailed` (fail-closed) |

USD quoting: `lastFx` younger than 30 minutes skips Chainlink; otherwise one
round per token, then `lastFx` until 24 hours. `PriceFallbackUsed` is only the
heartbeat-stale live path and the 24h cache-after-live-miss path, not the
30-minute hot cache.

That path is not Wallet D. The COA should publish an explicit score 0 once E is
reviewed so a later large swap of already-held funds is ALLOW.

## API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + Opinion for A–D |
| `POST` | `/oracle/:id/catch-up` | Publish deferred keeper score (Wallet D) |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (`txHash`) |
| `GET` | `/wallets/:id/compliance` | Pack for frontend Opinion (oracle-backed) |

## Schema keys (must match `types.ts`)

`finalScore`, `recommendedFeeBps`, `riskLevel` (`BLOCK` \| `ELEVATED` \| `STANDARD`),
`hookOutput` (`ALLOW` \| `FEE_OVERRIDE` \| `REVERT`), `scoreBreakdown`,
`triggeringFacts`, `regulatoryFlags`, `validity.calculatedAt` /
`validity.nextReview`, `auditHash`, `skillsApplied`, and per fact:
`factId`, `baseWeight`, `scoreContribution`, `regulatoryBasis`,
`justification`.

## Frontend

Opinion (`LegalOpinion`) consumes `compliance.agent.*`. The oracle fills those
fields using the FinCEN SAR Narrative Guidance model
(Who / What / When / Where / Why / How) as structure only — not a filing.
Agent skill filenames are never listed in the Opinion. SAR annex opens when
`hookOutput` is not `ALLOW`. Corpus documents used at calculation time appear
under Opinion **Normative basis** (`technicalOpinion.normativeCitations`).
