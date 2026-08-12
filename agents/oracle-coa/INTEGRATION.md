# Oracle COA — integration in aml-hook (demo)

This folder is the Compliance Officer Agent package (prompts + skills) used as
the **off-chain scoring oracle** for the UHI10 demo.

## Runtime today (MOCK_MODE)

The TypeScript runner lives in `apps/api/src/oracle/`:

| Module | Role |
|---|---|
| `agent.ts` | Skill flow FULL / INCREMENTAL + publish after score |
| `factScoring.ts` | `fact-scoring.md` over the in-memory ledger |
| `report.ts` | `task-regulatory-report` → Opinion UI pack |
| `store.ts` | In-memory score cache (demo beforeSwap read) |
| `onchainPublisher.ts` | Keeper → `ComplianceOracle.updateScore` (mock or rpc) |
| `types.ts` | `ScoreResult` · `OracleOpinion` · `ScorePublishResult` |

No live Anthropic / OpenSanctions / Etherscan calls. Facts are derived from
wallets, P2P transfers, and `SwapObserved` / `WalletBlocked` events. N-hop
decay (`100 × 0.65^hops`) stays the demo backbone so A/B/C/D remain demonstrable.

## FEE_OVERRIDE vs FeeEscrow (aligned with contracts)

| Layer | Behavior |
|---|---|
| COA / oracle | Publishes `finalScore` + `recommendedFeeBps` (total friction, e.g. 800 / 300) |
| `beforeSwap` | Ternary decision; does **not** set punitive `lpFeeOverride` — pool keeps standard fee |
| `afterSwap` on `FEE_OVERRIDE` | Hook takes differential (`feeBps − 30`) → `FeeEscrow.deposit` |
| FeeEscrow keeper | Checkpoint 1/2 / default after COA off-chain review (COA never writes escrow) |

Opinion copy must describe **standard pool fee + escrowed differential**, not
`lpFeeOverride` as the settlement path.

## Triggers

```
POST /transfers  → reevaluate(from) + reevaluate(to)   // before next swap
                 → exception: to=D defers keeper (stale score 0 for inflow demo)
POST /swaps      → afterSwap SwapObserved → reevaluate(wallet)
                 → or WalletBlocked → reevaluate(wallet)
                 → if D keeperPending: catch-up publish (~65) after latency swap
POST /oracle/:id/catch-up → manual deferred publish (Wallet D)
POST /reset      → clear + seed oracle for A–D
```

`beforeSwap` (simulated in quotes / swap route) reads the oracle cache, then
applies the §3.8 inflow floor when D has a significant USDC delta and pending keeper.

## API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + Opinion for A–D |
| `POST` | `/oracle/:id/catch-up` | Publish deferred keeper score (Wallet D) |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (mock or rpc tx) |
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
`hookOutput` is not `ALLOW`.
