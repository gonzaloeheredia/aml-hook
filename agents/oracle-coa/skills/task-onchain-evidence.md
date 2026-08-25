---
name: task-onchain-evidence
description: "Collect, organize, and validate on-chain evidence needed to evaluate a wallet. Covers block explorers, blockchain analytics engines, public designated-address registries, decentralized alert networks, third-party attestations, and the internal LP-report registry. Use after intake, before domain skills: produces the case file on which all analysis builds."
---

# Task: On-Chain Evidence — Evidence Collection

## Role

Structures information collection on an address. Defines which sources to
query, in what order, and how to organize results so domain skills work on
verifiable data. Does not evaluate substance: produces an ordered case file
with traceability for every datum.

**Principle.** Every fact that later contributes to the score must trace to
the source that produced it, with consultation time. A score without an
evidence chain is not defensible.

**Demo runtime.** Live vendor APIs are not called. Facts come from the Anvil
ledger (wallets, P2P transfers, `SwapObserved` / `WalletBlocked`) plus
`SanctionRegistry`. This skill remains the full product spec for a later
vendor-wired runtime.

---

## Expected inputs

| Field | Description |
|---|---|
| `eventId` | Intake-generated identifier |
| `address` | Address under analysis |
| `mode` | Evaluation mode from intake |
| `analysisWindow` | Period to cover |
| `keyQuestions` | What must be determined |
| `priorEvidence` | Prior case file, if any |

---

## Step 1: Source hierarchy

Hierarchy determines `confidence` of emitted `FactEvent`s.

### Level 1 — Official sources and verifiable on-chain state

| Source | Information | Confidence |
|---|---|---|
| OFAC SDN, UN, EU lists | Current designations | HIGH |
| On-chain designated-address mapping | Hook Layer 1, no external dependency at runtime | HIGH |
| Block explorer | Txs, contract code, `EXTCODESIZE`, multisig owners | HIGH |
| Hook-emitted events | `SwapObserved`, prior decisions, blocks | HIGH |

### Level 2 — Commercial analytics

| Source | Information | Confidence |
|---|---|---|
| Chainalysis / TRM / Elliptic / Solidus | Designated mapping, cluster attribution, exposure, DeFi manipulation | MEDIUM |

Cluster attribution is provider judgment — `MEDIUM` unless confirmed by a
second independent source.

### Level 3 — Decentralized / community

Forta, EAS attestations, Hypernative, DeFiLlama Hacks DB, open sanctioned-
address registries → typically `MEDIUM`.

### Level 4 — Protocol-internal signals

| Source | Information | Confidence |
|---|---|---|
| LP report registry | Staked LP reports | LOW individually; MEDIUM past threshold + challenge |
| Oracle history | Prior `ScoreResult` | HIGH on score value; basis inherits original confidence |
| Shared cross-pool registry | Aggregated signals from other pools | MEDIUM |

### Level 5 — Analytical inference

Percentiles, deviations, temporal correlations, wallet linkage → `LOW` unless
deterministic (verifiable co-spend in a concrete tx → `HIGH`).

---

## Step 2: Collection plan by dimension

| Dimension | Sources |
|---|---|
| **S — Sanctions** | Level 1 full; Level 2 for cluster |
| **ST — Structuring** | Hook events; explorer; analytical inference on series |
| **MX — Mixers** | Level 1 for designated contracts; Level 2 for tracing; explorer for direct verification |
| **NW — Network** | Explorer; Level 2; oracle for counterparty scores; DeFiLlama; LP reports |
| **GEO — Geography** | Level 2 only; always declare inference basis |
| **MT — Mitigants** | Oracle history; explorer protocol diversity; attestation registries |
| **DF — DeFi typologies** | Explorer + mempool/block adjacency + Level 2/3 alerts |

---

## Step 3: Case-file organization

Every collected item records: source, consultation time, effective window,
truncation status, and whether the source failed.

Distinguish always: **not found** / **not consulted** / **source failed**.

Pagination: declare retrieved vs reported totals; never conclude pattern
absence on a truncated series.

---

## Step 4: Gaps and degraded mode

| Gap type | Effect |
|---|---|
| Level-1 unavailable | Suspend evaluation or apply pool default; flag operational incident |
| Level-2 unavailable | Continue in degraded mode; declare limitation; do not invent cluster attribution |
| Truncated series | Declare; block aggregate structuring conclusions unless paginated |

---

## Structured output

```json
{
  "eventId": "...",
  "address": "0x...",
  "analysisWindow": {"from": "...", "to": "...", "effective": true},
  "sourcesConsulted": [
    {"source": "...", "level": 1, "status": "ok | empty | failed", "consultedAt": "..."}
  ],
  "factsCandidate": [],
  "gaps": ["..."],
  "degradedMode": false,
  "level1Available": true,
  "notes": "..."
}
```

> Candidate facts feed domain skills and `fact-scoring`. Final
> `triggeringFacts` on `ScoreResult` carry `factId`, `baseWeight`,
> `scoreContribution`, `regulatoryBasis`, `justification`.
