# AML Hook — Compliance Officer Agent (Oracle COA)

Off-chain Compliance Officer Agent pack: system prompt + modular skills for
behavioral wallet scoring. Spec for the TypeScript mock oracle at
`apps/api/src/oracle/` and for a future live agent runtime.

Derived from a financial-institution COA. This version drops identity-based
KYC flows and focuses on on-chain address behavior under U.S., EU, and FATF
frameworks.

```
agents/oracle-coa/
├── README.md                 # This file
├── INTEGRATION.md            # Wiring into aml-hook demo API / frontend
├── prompts/
│   └── system.md             # System prompt (forensic discipline)
└── skills/                   # Domain + task + scoring specs (kebab-case)

apps/api/src/oracle/           # CURRENT runtime (MOCK_MODE)
├── agent.ts                  # FULL / INCREMENTAL skill flow
├── factScoring.ts            # Deterministic fact-scoring over in-memory ledger
├── report.ts                 # Opinion pack (FinCEN Who–How narrative model)
├── store.ts                  # In-memory ComplianceOracle stand-in
├── types.ts                  # ScoreResult · OracleOpinion schemas
└── index.ts
```

There is **no** Python `agent.py` in this repo today. Skills are English
markdown specs consumed conceptually by the TypeScript mock; a future live
Claude loop may load them dynamically.

---

## Agent responsibilities

### 1. Wallet scoring

Run the full pipeline on an address: resolve originator attribution, screen
sanctions, gather on-chain evidence, apply domain skills, run `fact-scoring`,
and produce a 0–100 score with ternary hook output.

The signed score is written to the oracle cache. Simulated
`AMLHook.beforeSwap` reads it with no extra latency.

Entry point (mock): `reevaluateWallet()` in `apps/api/src/oracle/agent.ts`.

### 2. Evidence / Opinion pack

Technical Opinion with justified scoring, dimension findings with normative
citations, typologies, and recommendations. When warranted, a SAR-support
annex for the pool Compliance Officer (FinCEN narrative structure only — not
a filing).

Recipient of all documentary output: the pool operator’s Compliance Officer.
The agent never files with any authority.

Skill: `task-regulatory-report`. Mock builder: `buildOpinionFromScore()`.

### 3. Normative consultation (future live runtime)

Answer from a session-loaded corpus via `search_regulations`; declare coverage
gaps. Never answer from training memory in that module.

---

## Architectural constraint

The agent runs off-chain and asynchronously. The hook never invokes it at
swap time: it reads a precomputed score.

```
[Off-chain engine]                         [On-chain / demo]

event detected
      │
      ▼
  originator-attribution
      │
      ├── unresolved ──────────────▶ REVERT (ATTRIBUTION_FAILED)
      │
      ▼
  agent runs skill flow
      │
      ▼
  ScoreResult ─────────────────────▶  oracle store / ComplianceOracle
                                          │
                                          ▼
                                  AMLHook.beforeSwap()
                                    reads score → ternary output
                                          │
                                          ▼
                                  AMLHook.afterSwap()
                                    SwapObserved + FeeEscrow deposit on FEE_OVERRIDE
      │                                   │
      └───────────◀───────────────────────┘
        incremental recompute
```

**Demo N-hop backbone:** `derived_score = 100 × 0.65^hops` (closest hop wins).
Canonical wallets: A (score 100 / REVERT), B/C hop-1 (~65 / FEE_OVERRIDE 8%),
hop-2 (~42 / FEE_OVERRIDE 3%). On FEE_OVERRIDE, intended friction is
`recommendedFeeBps`; settlement = pool standard fee + differential in FeeEscrow.
---

## System prompt

`prompts/system.md` governs forensic discipline: mandatory citation with
`tx_hash` and block, correct explorer reading, distinction between not found /
not consulted / source failed, pagination and effective window, no value
inference, analytics output as third-party judgment, and receive-vs-use of
funds. Includes a twelve-point pre-output self-check.

---

## Current stack (demo)

| Layer | Implementation |
|---|---|
| Runtime | TypeScript `apps/api/src/oracle/` (MOCK_MODE) |
| Facts | Derived from wallets, P2P transfers, `SwapObserved` / `WalletBlocked` |
| Persistence | In-memory oracle store (no DB) |
| Skills | Markdown specs in `skills/` (kebab-case English filenames) |
| Live vendors | Not called (no Anthropic / OpenSanctions / Etherscan in mock) |

---

## Skill system

```
DIMENSION 1: DOMAIN                     DIMENSION 2: TASK TYPE

├── originator-attribution               ├── task-swap-intake
├── ofac-screening                       ├── task-onchain-evidence
├── wallet-screening                     ├── task-swap-decision
├── swap-behavior-analysis               ├── task-blocking-protocol
├── typology-detection                   └── task-regulatory-report
├── cross-pool-intelligence
└── protocol-obligations

── SCORING ──                            ── SYSTEM CONTROL ──
└── fact-scoring                         ├── model-validation
                                         └── dispute-remediation
```

### Standard workflow

```
[INPUT: swap / afterSwap / LP report / review / challenge]
          |
          v
  task-swap-intake
          |
          v
  originator-attribution           <-- ABSOLUTE PRECEDENCE
  ----------------------
  No attributed subject -> no analysis.
  Fail-closed: swap reverts.
          |
          v
  ofac-screening                   <-- PRECEDENCE OVER DOMAIN
  --------------
  Direct match -> task-blocking-protocol
          |
          v
  task-onchain-evidence
          |
          v
  wallet-screening -> swap-behavior-analysis -> typology-detection
          |
          v
  cross-pool-intelligence (query)
          |
          v
  fact-scoring -> task-swap-decision
          |
      +---+---+----------------+---------------------+
      v   v                v                     v
task-blocking-  task-regulatory-  cross-pool-      dispute-
protocol        report            intelligence     remediation
                                  (publish)
                                       |
                                       v
                                 model-validation
                                 (periodic)
```

### Precedence rules

1. `originator-attribution` runs first. No subject → no analysis.
2. `ofac-screening` runs before every other domain skill.
3. `swap-behavior-analysis` is mandatory before emitting a block-band score.
4. `protocol-obligations` runs when configuring a pool and before any SAR annex.

### Incremental post-swap flow

```
afterSwap emits SwapObserved (+ FeeEscrow deposit on FEE_OVERRIDE)
          │
          ▼
  task-swap-intake (POST_SWAP mode)
          │
          ├─ score valid, no new S/MX/GEO facts ─▶ swap-behavior-analysis
          │                                        + incremental fact-scoring → oracle
          ├─ score expired or invalidated ───────▶ full flow
          └─ new sanctions/TF fact on the subject ─▶ task-blocking-protocol
             (notify operator; hook cannot unwind a confirmed swap)
```

Mock flows (`agent.ts`):

```
FULL_FLOW = [
  task-swap-intake, originator-attribution, ofac-screening,
  task-onchain-evidence, wallet-screening, swap-behavior-analysis,
  typology-detection, cross-pool-intelligence, fact-scoring,
  task-swap-decision, task-regulatory-report,
]

INCREMENTAL_FLOW = [
  task-swap-intake, swap-behavior-analysis, fact-scoring,
  task-swap-decision, task-regulatory-report,
]
```

### Common combinations

| Case | Domain skills | Flow |
|---|---|---|
| Swap via unregistered router | `originator-attribution` | intake → attribution → **REVERT** |
| Swap via trusted forwarder | Full flow | intake → … → scoring → decision |
| New wallet, no score | `ofac-screening` + `wallet-screening` | full |
| Post-swap update | `swap-behavior-analysis` | incremental |
| OFAC SDN hit | `ofac-screening` | → **blocking-protocol** → report |
| Structuring / smurfing | behavior + typology | full → report |
| Flash-loan manipulation | `typology-detection` | full → report |
| ERC-6909 internal claims | `typology-detection` | full → report |
| Address poisoning of a third party | `typology-detection` | receive-vs-use rule |
| Signal from another pool | `cross-pool-intelligence` | query → capped scoring |
| LP challenge report | `dispute-remediation` | challenge → resolve → score |
| Wallet disputes its block | `dispute-remediation` | admissibility → recalc |
| Periodic validation | `model-validation` | backtest → sensitivity → drift |
| New pool setup | `protocol-obligations` | intake → domain → report |

---

## Autonomy limits

| Limit | Condition |
|---|---|
| **Immediate revert** | Originator attribution unresolved under restrictive policy |
| **Immediate block** | Confirmed OFAC SDN / UN / EU match |
| **Immediate block** | Interaction with a designated contract |
| **Immediate block** | Nexus to TF / proliferation financing |
| **Preventive block + human review** | Designated controller on a Smart Account |
| **Human review required** | Cluster-attribution match |
| **Human review required** | Score ≥ 71 with no HIGH-confidence fact |
| **Human review required** | Block based only on unverified external signals |
| **Human review required** | Dispute resolution that unlocks a wallet |
| **Suspend evaluation** | Level-1 sources unavailable |
| **Legal advice required** | Whether the operator is a BSA obligated person |

The agent never:

- Files a report with any authority
- Answers an authority request directly
- Tips off the evaluated subject about an analysis or report
- Releases custodied funds without documented Compliance Officer instruction
- Unlocks a wallet with an active sanctions override
- Changes governable parameters outside the DAO Timelock
- Publishes effective threshold values
- Re-publishes another pool’s signal as its own
- Builds a risk profile on a router, aggregator, or infrastructure contract
- Concludes that an entity is an obligated person or that conduct is a crime

---

## Score → hook output (immutable mapping)

| Score | `riskLevel` | `hookOutput` |
|---|---|---|
| 0–30 | `STANDARD` | `ALLOW` (pool standard fee, e.g. 0.30%) |
| 31–70 | `ELEVATED` | `FEE_OVERRIDE` (risk differential → `FeeEscrow` 48h; pool keeps standard fee) |
| 71–100 | `BLOCK` | `REVERT` |

**FEE_OVERRIDE settlement (on-chain).** `beforeSwap` does **not** set a punitive
`lpFeeOverride`. The pool charges its standard LP fee. In `afterSwap`, the hook
takes the risk differential (`recommendedFeeBps − standardFeeBps`, e.g. 800−30)
via `poolManager.take` and deposits it into `FeeEscrow`. The COA never writes
escrow; a FeeEscrow keeper resolves after off-chain COA review (Checkpoint 1/2).

`recommendedFeeBps` remains the COA/oracle source of truth for total intended
friction (demo quotes + keeper `updateScore` fee field).

Schema keys match `apps/api/src/oracle/types.ts`: `finalScore`, `riskLevel`,
`hookOutput`, `scoreBreakdown`, `triggeringFacts`, `regulatoryFlags`,
`validity.calculatedAt` / `nextReview`, `auditHash`, `skillsApplied`,
and per-fact `factId`, `baseWeight`, `scoreContribution`, `regulatoryBasis`,
`justification`.

**Opinion rule:** skill filenames must **not** appear in Opinion sources
(`technicalOpinion.sourcesConsulted` or SAR annex). Skills are internal
instruments; the Opinion cites facts, addresses, amounts, dates, and norms.

---

## Regulatory framework

| Framework | Scope |
|---|---|
| FATF — 40 Recommendations (2023) | Base standard for all scoring |
| FATF — VA Red Flag Indicators (2020) | Typology catalog; six categories |
| FATF — VA / VASP Guidance (2021) | Actor qualification in decentralized settings |
| OFAC — IEEPA, 31 CFR Part 501 | Blocking, segregation, blocked-property reporting |
| OFAC — VC Industry Guidance (2021) | Address screening and exposure monitoring |
| BSA — 31 U.S.C. § 5311 et seq., 31 CFR § 1010.320 | AML program, monitoring, SAR regime |
| BSA — 31 CFR § 1010.410(e)–(f) | U.S. Travel Rule; USD 3,000 threshold |
| MiCA — Regulation (EU) 2023/1114 | CASP regime |
| TFR — Regulation (EU) 2023/1113 | EU Travel Rule; zero threshold |
| AMLR — Regulation (EU) 2024/1624 | Unified due-diligence regime |

**Travel Rule.** Applies to VASP-to-VASP transfers, not to the swap itself. A
swap has no two institutions, no distinct originator/beneficiary, and custody
remains with the user. Inside this system it acts as: mitigant on the prior
leg, operator obligation if custodial services are offered, and perimeter
where compliance already exists. See `protocol-obligations`.

---

## Governable parameters (reference)

Defaults aligned with the mock / product docs (values may be overridden by
DAO Timelock in a live deployment):

| Parameter | Default |
|---|---|
| Report threshold USD | 10,000 |
| Structuring window (days) | 30 |
| Min structuring splits | 3 |
| Velocity spike multiplier | 5 |
| Mixer lookback (days) | 90 |
| Historical blend `decay_factor` | 0.4 |
| Reasonable-suspicion score threshold | 65 |
| N-hop decay factor (demo) | 0.65 |
| Hop depth | 3 |
| Fee escrow timelock (hours) | 48 |
| Attribution policy | restrictive |
| Unverified external signal weight | 0.5 |
| LP report challenge (hours) | 72 |
| Periodic block review (days) | 90 |
| Record retention (years) | 5 |

**Immutables:** sanctions override, score→output mapping, mandatory oracle
signature (live), two-dimension suspicion rule, HIGH fact required for block,
mitigant cap, external-signal ceiling, no re-publication, shared-registry
excludes raw scores, sanctions verified against list.

---

## Changes vs financial-institution COA

| Original skill | Status | Replacement |
|---|---|---|
| `aml-cft-screening` | Rewritten | `typology-detection` |
| `crypto-asset-screening` | Rewritten | `wallet-screening` |
| `defi-onchain-risk` | Rewritten | `swap-behavior-analysis` |
| `sanctions-screening` | Rewritten | `ofac-screening` |
| `vasp-regulatory-compliance` | Rewritten | `protocol-obligations` |
| `kyc-due-diligence` | Removed | No onboarding / verified identity |
| `task-intake-triage` | Rewritten | `task-swap-intake` |
| `task-investigation` | Rewritten | `task-onchain-evidence` |
| `task-risk-assessment` | Rewritten | `task-swap-decision` |
| `task-escalation` | Rewritten | `task-blocking-protocol` |
| `task-report-drafting` | Rewritten | `task-regulatory-report` |
| `fact-scoring` | Adapted | Wallet catalog + DeFi dimension |
| — | New | `originator-attribution`, `model-validation`, `dispute-remediation`, `cross-pool-intelligence`, `prompts/system.md` |

Removed: Argentine supervisors (UIF/CNV/BCRA), ROS/RFT, Ley 25.246, PEP/UBO
documentary KYC, identity OSINT.

---

*AML Hook — Compliance Officer Agent v3.0 (oracle-coa)*
*Gonzalo Emanuel Heredia — Uniswap Hook Incubator, Cohort 10*
