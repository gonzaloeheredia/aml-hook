# Oracle COA (Compliance Officer Agent): integration in aml-hook (demo)

This folder is the COA package (prompts + skills) used as
the **off-chain scoring oracle** for the UHI10 demo.

## Runtime

The TypeScript runner lives in `apps/api/src/oracle/`. With `ANTHROPIC_API_KEY`,
Claude emits score, fee, and Opinion (`liveScore.ts`). Tools:
`consult_skill` (call `uhi10-use-case` before scoring A–E),
`search_regulations`, `get_active_version_at`, `screen_ofac`. The keeper publishes
`finalScore` + `recommendedFeeBps` into the API cache for A–D (no chain write).
A–D quotes use hop + band. A 3-minute tick is Sepolia-only freshness. Without a key, `COA_LIVE=0`, or `npm test`, `factScoring.ts`
interprets the skills. Every evaluation (and every Opinion) screens the
subject against the live OFAC SDN ETH list. A–D skip the `SanctionRegistry` write.
The live swap still only reads that mapping.

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
| `onchainPublisher.ts` | Keeper → `ComplianceOracle.updateScore` (signed RPC (remote procedure call), or fail). The attestor must sign `attestationHash(wallet, score, hopDistance, origin, feeBps, updatedAt, chainid)`. A score-only or empty signature is rejected. |
| `ofacSdn.ts` / `ofacScreen.ts` | Live OFAC SDN ETH set + `setSanctioned` writer |
| `types.ts` | `ScoreResult` · `OracleOpinion` · `ScorePublishResult` |

No live OpenSanctions / Etherscan / Chainalysis calls. Facts for A–D come from
the API store (wallets, P2P, demo `SwapObserved` / `WalletBlocked`) plus live OFAC SDN.
N-hop decay (`100 × 0.65^hops`) is the A–D backbone in skill `uhi10-use-case`.
Do not import that ledger onto a Sepolia EOA. The live pool (`docs/Sepolia.md`)
needs a keeper/attestor if a new wallet must leave the never-scored band.

## FEE_OVERRIDE vs FeeEscrow (aligned with contracts)

| Moment | What happens |
|---|---|
| `afterSwap` on `FEE_OVERRIDE` | Hook takes differential (`feeBps − 30`) → `FeeEscrow.deposit` (`RiskFee`) |
| `afterAddLiquidity` on 31–70 / never-scored 3%/8% | Hook takes the **full** override → `FeeEscrow.deposit` (`RiskFee`) |
| Blocked LP (liquidity provider) remove | Principal → `LpPrincipal`; `feesAccrued` → `RiskFee`. Both 48h. |
| FeeEscrow keeper | Checkpoint 1/2 / default after COA off-chain review (COA never writes escrow) |
| Clean Checkpoint 2 | Risk fee → LpCompensationVault (LP claim after epoch). Principal → LP wallet. |
| Illicit recover | `ILLICIT_RISK_FEE` vs `LP_PRINCIPAL` by kind |

| Layer | Behavior |
|---|---|
| COA / oracle | Publishes `finalScore` + `recommendedFeeBps` (total friction, e.g. 800 / 300) |
| `beforeSwap` | Ternary decision. Does **not** set punitive `lpFeeOverride`. The pool keeps the standard fee. |

Opinion copy must describe **standard pool fee + escrowed differential**.
`lpFeeOverride` is not the settlement path.

## Triggers

```
POST /transfers  → A–D store hop + balances; COA may refresh in background
POST /swaps      → A–D applyPoolSwap + demo event; COA fire-and-forget
POST /oracle/:id/catch-up → deferred D score in memory
POST /reset      → resetStore + in-memory seed A–D (E unpublished)
keeper tick 3m   → Sepolia freshness only (not A–D)
```

A–D quotes and swaps use TypeScript hop + band (same mapping as `RiskPolicy.decide`).
They do not call `AmlHook.previewSwap`. Floor B on A–D uses the demo clock
(`POST /demo/elapse`). A wallet with no oracle row is Mitigation A (Wallet E):
live `beforeSwap` on Sepolia applies Floor A/C/D by USD size. The faucet does
not publish a score. Simulator C→E does not fund that EOA.

| Assessed USD-8 | Hook output |
|---|---|
| < `unscoredFeeThreshold` (default $1,000 / `1_000e8`) | `FEE_OVERRIDE` 3% |
| $1,000 – $14,999 | `FEE_OVERRIDE` 8% |
| ≥ `unscoredRevertThreshold` (default $15,000 / `15_000e8`) this swap | `UnscoredMagnitudeBlocked` |
| Prior 24h USD > 0 and prior + this swap ≥ $15,000 | `DailyAggregationBlocked` (Floor C) |
| No live round and no `lastFx` within 24h | `MagnitudeQuoteFailed` (fail-closed) |

USD quoting: `lastFx` younger than 30 minutes skips Chainlink. Otherwise one
round per token, then `lastFx` until 24 hours. `PriceFallbackUsed` is only the
heartbeat-stale live path and the 24h cache-after-live-miss path. It is not the
30-minute hot cache.

That path is not Wallet D. Publish an explicit score 0 once E is
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
fields using the FinCEN (Financial Crimes Enforcement Network) SAR (Suspicious Activity Report) Narrative Guidance model
(Who / What / When / Where / Why / How) as structure only. The model is not a filing.
Agent skill filenames are never listed in the Opinion. SAR annex opens when
`hookOutput` is not `ALLOW`. Corpus documents used at calculation time appear
under Opinion **Normative basis** (`technicalOpinion.normativeCitations`).
