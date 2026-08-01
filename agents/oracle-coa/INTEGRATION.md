# Oracle COA — integration in aml-hook (demo)

This folder is the Compliance Officer Agent package (prompts + skills) used as
the **off-chain scoring oracle** for the UHI10 demo. Smart contracts come later.

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
decay (`100 × 0.65^hops`) stays the demo backbone so A/B/C remain demonstrable.

## Triggers

```
POST /transfers  → reevaluate(from) + reevaluate(to)   // before next swap
POST /swaps      → afterSwap SwapObserved → reevaluate(wallet)
                 → or WalletBlocked → reevaluate(wallet)
POST /reset      → clear + seed oracle for A/B/C
```

`beforeSwap` (simulated in quotes / swap route) **only reads** `walletScore()`
from the oracle cache.

## API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + Opinion for A/B/C |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (mock or rpc tx) |
| `GET` | `/wallets/:id/compliance` | Pack for frontend Opinion (oracle-backed) |

## Schema keys (must match `types.ts`)

`finalScore`, `riskLevel` (`BLOCK` \| `ELEVATED` \| `STANDARD`),
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
