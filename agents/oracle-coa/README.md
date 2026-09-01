# AML (Anti-Money Laundering) Hook: Compliance Officer Agent (Oracle COA)

Off-chain COA pack: system prompt + modular skills for
behavioral wallet scoring. Runtime is `apps/api/src/oracle/`: live Claude when
`ANTHROPIC_API_KEY` is set; skill interpreter otherwise.

Derived from a financial-institution COA. This version drops identity-based
KYC (Know Your Customer) flows and focuses on on-chain address behavior under U.S., EU (European Union), and FATF (Financial Action Task Force)
frameworks.

```
agents/oracle-coa/
├── README.md                 # This file
├── INTEGRATION.md            # Wiring into aml-hook demo API / frontend
├── prompts/
│   └── system.md             # System prompt (forensic discipline)
└── skills/                   # Domain + task + scoring specs (kebab-case)

apps/api/src/oracle/           # Runtime (live Claude if key set)
├── agent.ts                  # FULL / INCREMENTAL + publish
├── liveScore.ts              # Claude score + fee + Opinion
├── liveOpinion.ts            # Tools: search_regulations, consult_skill
├── keeper.ts                 # 3-minute freshness stamp (no Claude)
├── skills.ts                 # Load agents/oracle-coa/skills/*.md
├── factScoring.ts            # Skill interpreter (tests / COA_LIVE=0)
├── report.ts                 # Opinion schema skeleton
├── store.ts                  # Cache. A–D quotes use memory hop + band
├── types.ts                  # ScoreResult · OracleOpinion schemas
└── index.ts
```

There is **no** Python `agent.py` in this repo. Skills are English markdown
in `skills/`. Live Claude loads them with `consult_skill` (use `uhi10-use-case`
when A–E constraints are unclear; `uhi10-sepolia` for the live pool). Tests
and `COA_LIVE=0` use `factScoring.ts`.

## Agent responsibilities

### 1. Wallet scoring

Run the full pipeline on an address: resolve originator attribution, screen
sanctions, gather on-chain evidence, apply domain skills, run `fact-scoring`,
and produce a 0–100 score with ternary hook output.

For A–D the signed score stays in the API cache (no `ComplianceOracle` write).
`AMLHook.beforeSwap` on Sepolia reads a published row only for live subjects
(Wallet E). See `docs/Whitepaper.md` (Stack).

Entry point: `reevaluateWallet()` in `apps/api/src/oracle/agent.ts`.

### 2. Evidence / Opinion pack

Technical Opinion with justified scoring, dimension findings with normative
citations, typologies, and recommendations. When warranted, a SAR (Suspicious Activity Report)-support
annex for the pool Compliance Officer (FinCEN (Financial Crimes Enforcement Network) narrative structure only.
The annex is not a filing).

Recipient of all documentary output: the pool operator’s Compliance Officer.
The agent never files with any authority.

Skill: `task-regulatory-report`. Live narrative: Claude. Schema fill:
`buildOpinionFromScore()` / `overlayOpinion()`.

### 3. Normative consultation

Answer from the git-versioned corpus at `corpus/` via `search_regulations`
(`apps/api/src/oracle/corpus.ts`). Cite `id`, `publicationDate`, and
`retrievedAt` on the Opinion. Declare a coverage gap when the manifest has no
in-force document. Never answer from training memory in that module.

## Architectural constraint

The agent runs off-chain and asynchronously (Claude when the API key is set;
skill interpreter otherwise). It consults `uhi10-use-case` before emitting
`finalScore`. The hook never invokes it at swap time: it reads a published
score. The keeper only writes `ComplianceOracle`.

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
hop-2 (~42 / FEE_OVERRIDE 3%), D (published clean + inflow / 8% at $15k),
E (never written, starts empty, funded by C: Floor A is this swap; Floor D is the bag).
Wallet A is a confirmed exploit (score 100 · `WalletBlocked`; not OFAC (Office of Foreign Assets Control)-listed).
Named-address OFAC (`SanctionHit` at Layer 1) is hook functionality. It is not a demo wallet.
On FEE_OVERRIDE, intended friction is `recommendedFeeBps` when the keeper wrote
one. Never-scored bands are hook-local USD-8 (United States dollar, 8 decimals) (`lastFx` if younger than 30 minutes, else Chainlink). Settlement = pool
standard fee + differential in FeeEscrow.

## System prompt

`prompts/system.md` governs forensic discipline: mandatory citation with
`tx_hash` and block, correct explorer reading, distinction between not found /
not consulted / source failed, pagination and effective window, no value
inference, analytics output as third-party judgment, and receive-vs-use of
funds. Includes a thirteen-point pre-output self-check.

## Demo stack

| Layer | Implementation |
|---|---|
| Runtime | TypeScript `apps/api/src/oracle/` (Claude if key set; else skill interpreter) |
| Facts | Wallets, P2P (peer-to-peer) transfers, `SwapObserved` / `WalletBlocked`, SanctionRegistry |
| Persistence | In-memory cache + `ComplianceOracle.updateScore` |
| Skills | Markdown in `skills/`; live tool `consult_skill` (`uhi10-use-case`) |
| Live vendors | Anthropic for score + Opinion. Corpus via `search_regulations`. No OpenSanctions / Etherscan |

## Skill system

```
DIMENSION 1: DOMAIN                     DIMENSION 2: TASK TYPE

├── originator-attribution               ├── task-swap-intake
├── ofac-screening                       ├── task-onchain-evidence
├── wallet-screening                     ├── task-swap-decision
├── swap-behavior-analysis               ├── task-blocking-protocol
├── typology-detection                   └── task-regulatory-report
├── cross-pool-intelligence
├── protocol-obligations
├── uhi10-use-case                       (A–E demo validations; consult when unsure)
└── uhi10-sepolia                        (Sepolia live pool; never-scored EOA (externally owned account) = Wallet E)

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
  uhi10-use-case (A–E validations; consult when unsure)
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
          │                                        + uhi10-use-case
          │                                        + incremental fact-scoring → oracle
          ├─ score expired or invalidated ───────▶ full flow
          └─ new sanctions/TF fact on the subject ─▶ task-blocking-protocol
             (notify operator; hook cannot unwind a confirmed swap)
```

Skill flows (`agent.ts`):

```
FULL_FLOW = [
  task-swap-intake, originator-attribution, ofac-screening,
  task-onchain-evidence, wallet-screening, swap-behavior-analysis,
  typology-detection, cross-pool-intelligence, uhi10-use-case, fact-scoring,
  task-swap-decision, search_regulations, task-regulatory-report,
]

INCREMENTAL_FLOW = [
  task-swap-intake, swap-behavior-analysis, uhi10-use-case, fact-scoring,
  task-swap-decision, search_regulations, task-regulatory-report,
]
```

### Common combinations

| Case | Domain skills | Flow |
|---|---|---|
| Swap via unregistered router | `originator-attribution` | intake → attribution → **REVERT** |
| Swap via trusted forwarder | Full flow | intake → … → scoring → decision |
| New wallet, no score | `ofac-screening` + `wallet-screening` | full |
| Post-swap update | `swap-behavior-analysis` | incremental |
| OFAC SDN (Specially Designated Nationals) hit | `ofac-screening` | → **blocking-protocol** → report |
| Structuring / smurfing | behavior + typology | full → report |
| Flash-loan manipulation | `typology-detection` | full → report |
| ERC-6909 internal claims | `typology-detection` | full → report |
| Address poisoning of a third party | `typology-detection` | receive-vs-use rule |
| Signal from another pool | `cross-pool-intelligence` | query → capped scoring |
| LP (liquidity provider) challenge report | `dispute-remediation` | challenge → resolve → score |
| Wallet disputes its block | `dispute-remediation` | admissibility → recalc |
| Periodic validation | `model-validation` | backtest → sensitivity → drift |
| New pool setup | `protocol-obligations` | intake → domain → report |

## Autonomy limits

| Limit | Condition |
|---|---|
| The swap reverts in that transaction | Originator attribution unresolved under restrictive policy |
| The swap reverts in that transaction | Confirmed OFAC SDN / UN (United Nations) / EU match |
| The swap reverts in that transaction | Interaction with a designated contract |
| The swap reverts in that transaction | Nexus to TF (terrorist financing) / proliferation financing |
| Preventive block + human review | Designated controller on a Smart Account |
| Human review required | Cluster-attribution match |
| Human review required | Score ≥ 71 with no HIGH-confidence fact |
| Human review required | Block based only on unverified external signals |
| Human review required | Dispute resolution that unlocks a wallet |
| Suspend evaluation | Level-1 sources unavailable |
| Legal advice required | Whether the operator is a BSA (Bank Secrecy Act) obligated person |

The agent never:

- Files a report with any authority
- Answers an authority request directly
- Tips off the evaluated subject about an analysis or report
- Releases custodied funds without documented Compliance Officer instruction
- Unlocks a wallet with an active sanctions override
- Changes governable parameters outside the DAO (decentralized autonomous organization) Timelock
- Publishes effective threshold values
- Re-publishes another pool’s signal as its own
- Builds a risk profile on a router, aggregator, or infrastructure contract
- Concludes that an entity is an obligated person or that conduct is a crime

## Score → hook output (immutable mapping)

| Score | `riskLevel` | `hookOutput` |
|---|---|---|
| 0–30 | `STANDARD` | `ALLOW` (pool standard fee, e.g. 0.30%) |
| 31–70 | `ELEVATED` | `FEE_OVERRIDE` (risk differential → `FeeEscrow` 48h; pool keeps standard fee) |
| 71–100 | `BLOCK` | `REVERT` |
| Never written (`updatedAt == 0`), assessed USD < $1,000 | n/a (no row) | `FEE_OVERRIDE` 3%: Floor A dust, unless Floor D on the bag is stricter |
| Never written, $1,000–$14,999 | n/a | `FEE_OVERRIDE` 8% |
| Never written, unpublished bag ≥ $15,000 (swap may be smaller) | n/a | `FEE_OVERRIDE` 8%: Floor D on E; demo E starts empty, then C funds the bag |
| Never written, this swap ≥ $15,000 | n/a | `REVERT` `UnscoredMagnitudeBlocked` |
| Any wallet, prior 24h USD + this swap crosses $15,000 | n/a | `REVERT` `DailyAggregationBlocked` (Floor C) |
| Never written, no live feed and no `lastFx` within 24h | n/a | `REVERT` `MagnitudeQuoteFailed` (fail-closed) |

Those last four rows are **not** a COA score. If `lastFx` is younger than 30
minutes the hook does not call Chainlink. Otherwise it reads each token's
feed **once per swap** and applies that price to every amount (ticket,
inbound, bag, settled). A usable round is cached as `lastFx`. A missing live
round uses that cache for up to 24 hours. Only then does it fail-close.
Deploy binds official ETH/USD and USDC/USD on live chains. Anvil uses
`MockUsdFeed`. Extra tokens go through the governor's `setPriceFeed`. The
compliance officer retunes the USD floors after a 48h confirm. Publish score 0
with a non-zero `updatedAt` when the wallet is confirmed-clean so magnitude
REVERT stops applying to already-held funds.

**FEE_OVERRIDE settlement (on-chain).** `beforeSwap` does **not** set a punitive
`lpFeeOverride`. The pool charges its standard LP fee. In `afterSwap`, the hook
takes the risk differential (`recommendedFeeBps − standardFeeBps`, e.g. 800−30)
via `poolManager.take` and deposits it into `FeeEscrow`. The COA never writes
escrow. A FeeEscrow keeper resolves after off-chain COA review (whitepaper §8.3).
Clean / early / default → LpCompensationVault. Confirmed illicit → blocked,
then recovered to the compliance reserve only. Never the LP fund.

`recommendedFeeBps` remains the COA/oracle source of truth for total intended
friction (demo quotes + keeper `updateScore` fee field).

Schema keys match `apps/api/src/oracle/types.ts`: `finalScore`, `riskLevel`,
`hookOutput`, `scoreBreakdown`, `triggeringFacts`, `regulatoryFlags`,
`validity.calculatedAt` / `nextReview`, `auditHash`, `skillsApplied`,
and per-fact `factId`, `baseWeight`, `scoreContribution`, `regulatoryBasis`,
`justification`.

**Opinion rule:** skill filenames must **not** appear in Opinion sources
(`technicalOpinion.sourcesConsulted` or SAR annex). Skills are internal
instruments. The Opinion cites facts, addresses, amounts, dates, and norms.

## Regulatory framework

| Framework | Scope |
|---|---|
| FATF: 40 Recommendations (2023) | Base standard for all scoring |
| FATF: VA Red Flag Indicators (2020) | Typology catalog; six categories |
| FATF: VA / VASP (virtual asset service provider) Guidance (2021) | Actor qualification in decentralized settings |
| OFAC: IEEPA (International Emergency Economic Powers Act), 31 CFR (Code of Federal Regulations) Part 501 | Blocking, segregation, blocked-property reporting |
| OFAC: VC Industry Guidance (2021) | Address screening and exposure monitoring |
| BSA: 31 U.S.C. § 5311 et seq., 31 CFR § 1010.320 | AML program, monitoring, SAR regime |
| BSA: 31 CFR § 1010.410(e)–(f) | U.S. Travel Rule; USD 3,000 threshold |
| MiCA (Markets in Crypto-Assets): Regulation (EU) 2023/1114 | CASP (crypto-asset service provider) regime |
| TFR (Transfer of Funds Regulation): Regulation (EU) 2023/1113 | EU Travel Rule; zero threshold |
| AMLR (Anti-Money Laundering Regulation): Regulation (EU) 2024/1624 | Unified due-diligence regime |

**Travel Rule.** Applies to VASP-to-VASP transfers. The swap itself is outside that scope. A
swap has no two institutions, no distinct originator/beneficiary, and custody
remains with the user. Inside this system it acts as: mitigant on the prior
leg, operator obligation if custodial services are offered, and perimeter
where compliance already exists. See `protocol-obligations`.

## Governable parameters (reference)

Defaults aligned with the product docs (values may be overridden by
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
| (none) | New | `originator-attribution`, `model-validation`, `dispute-remediation`, `cross-pool-intelligence`, `prompts/system.md` |

Removed: Argentine supervisors (UIF/CNV/BCRA), ROS/RFT, Ley 25.246, PEP (politically exposed person) / UBO (ultimate beneficial owner)
documentary KYC, identity OSINT (open-source intelligence).

*AML Hook: Compliance Officer Agent (COA) v3.0 (oracle-coa)*
*Gonzalo Emanuel Heredia*
