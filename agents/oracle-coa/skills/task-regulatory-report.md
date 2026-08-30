---
name: task-regulatory-report
description: "Draft the evidence pack the pool operator delivers to its own Compliance Officer: technical Opinion with justified scoring, SAR-support annex for a possible FinCEN filing, decision record, and pool aggregate report. Use after task-swap-decision when reasonable suspicion is reached, when a block executed, or when the operator requests a period pack. The agent never files with any authority. Live: Claude. Schema: apps/api/src/oracle/report.ts."
---

# Task: Regulatory Report: Evidence / Opinion Pack

## Role

Transforms prior analysis into formal documentation. Does not generate new
analysis: structures and formalizes what earlier skills produced.

**Recipient.** Pool operator’s Compliance Officer. The agent produces evidence
and drafts for review. It does not file with FinCEN (Financial Crimes
Enforcement Network), OFAC (Office of Foreign Assets Control), any European
authority, or any supervisor. Filing requires human review and signature.

**Purpose.** Enable the operator to show a supervisor or auditor that the pool
had a reasonable monitoring system, each decision had normative basis, and the
chain from conclusion to on-chain evidence is reconstructible.

**Live:** Claude drafts the Opinion after the score (corpus via
`search_regulations`). **Interpreter** (`COA_LIVE=0` / tests):
`buildOpinionFromScore()` in `apps/api/src/oracle/report.ts` maps
`ScoreResult` → `OracleOpinion` for the frontend Opinion UI (user interface).

---

## Expected inputs

| Field | Description |
|---|---|
| `documentType` | `opinion` · `sar-annex` · `decision-record` · `pool-report` · `authority-request-pack` |
| `eventId` | Event identifier |
| `swapDecision` | Output of `task-swap-decision` |
| `scoreResult` | Output of `fact-scoring` (`ScoreResult`) |
| `typologyOutput` | Identified typologies |
| `caseFile` | Output of `task-onchain-evidence` |
| `blockingOutput` | Output of `task-blocking-protocol`, if activated |
| `protocolObligations` | Operator applicable framework |
| `period` | Time range for aggregate report |

---

## A. Technical Opinion

Base document. Issued for every `REVERT`, every block, and every
`REASONABLE_SUSPICION_REACHED` signal. Also issued in abbreviated form for
`ALLOW` (verification that no SAR (Suspicious Activity Report) annex was opened).

**Narrative model.** Body follows FinCEN *Guidance on Preparing A Complete &
Sufficient Suspicious Activity Report Narrative* (Nov 2003). **Internal
structure only** (Who / What / When / Where / Why / How). Not a filed SAR.

**Skills must not appear in the Opinion.** Text and annex cite facts,
addresses, amounts, dates, on-chain events, and normative bases. **Never**
list agent skill names (`ofac-screening`, `fact-scoring`, `task-*`,
`skills/…`). Skills are internal instruments, not Opinion sources.

```
TECHNICAL COMPLIANCE OPINION: AML HOOK
════════════════════════════════════════════════════════════

Event:           [ID]
Pool:            [0x...]
Wallet:          [0x...]
Issued:          [ISO 8601]
Block:           [N]
Recipient:       Pool operator Compliance Officer
Character:       Internal evidence. Not a report to any authority.
Model:           FinCEN SAR Narrative Guidance (Who / What / When / Where / Why / How). Not a filing

1. WHO: SUBJECT(S)
════════════════════════════════════════════════════════════
Address(es) under review, role (originator / intermediary / beneficiary),
known graph relationships (hop origin, cluster if recorded).
No verified identity in a permissionless pool.

2. WHAT: INSTRUMENTS AND PATTERNS
════════════════════════════════════════════════════════════
Instrument (USDC→ETH swap, ERC-20 P2P (peer-to-peer), etc.), FATF (Financial
Action Task Force) typologies / indicators observed, on-chain evidence
(tx_hash / block), sanctions screen result (hit or clear verification).

3. WHEN: TEMPORALITY
════════════════════════════════════════════════════════════
Evaluation timestamp, trigger, suspicious-activity period, next review.
No dense tables; individual dates remain in the ledger.

4. WHERE: VENUE AND ADDRESSES
════════════════════════════════════════════════════════════
Venue (Uniswap v4 pool / network), address under review, P2P hop path,
corridors or jurisdictions only if in evidence.

5. WHY: WHY UNUSUAL / ELEVATED
════════════════════════════════════════════════════════════
Score and band (ALLOW / FEE_OVERRIDE / REVERT), triggeringFacts with
scoreContribution, contrast to expected pool profile. Do not conclude crime.

6. HOW: METHOD OF OPERATION AND CONTROL
════════════════════════════════════════════════════════════
Modus (cash-out, hop, ordinary swap) and hook response
(ALLOW / FEE_OVERRIDE / REVERT), emitted event, treatment of funds.

7. NORMATIVE BASIS
════════════════════════════════════════════════════════════
Standard supporting each conclusion (FATF, OFAC, BSA (Bank Secrecy Act)/FinCEN
as narrative model framework, EU (European Union) framework if applicable).

8. RECOMMENDATIONS TO THE COMPLIANCE OFFICER
════════════════════════════════════════════════════════════
Suggested actions, timelines, tip-off prohibition, human decision.

9. TRACEABILITY
════════════════════════════════════════════════════════════
auditHash: [hash]
On-chain events emitted: [list with block]
Supporting evidence (ledger / emits / screen). No skill filenames
Retention: 5 years (FATF Rec. 11; BSA)
```

---

## B. SAR-support annex

Produced when reasonable suspicion was reached **and** (live) 
`protocol-obligations` assessed the operator as a likely BSA obligated person.
In the UHI10 demo, annex opens whenever `hookOutput !== ALLOW`.

**Nature.** Support annex, not a submitted form. The obligated person files
electronically with FinCEN through their own access. The agent supplies
analytical material for the Compliance Officer.

**Field rule.** If a datum is not in the case file, leave the field empty. No
placeholders.

### B.1 Activity data

| Field | Content | Source |
|---|---|---|
| Initial detection date | When the system reached reasonable suspicion (starts 30-day clock) | `ScoreResult` |
| Activity period | Suspicious period only, not full wallet history | behavior analysis |
| Amount involved | Sum of operations in the pattern, no decimals | swap / transfer series |
| Asset and network | Token, pair, chain | intake |
| Operation state | Executed, executed with FEE_OVERRIDE, or reverted | `task-swap-decision` / `hookOutput` |

### B.2 Subjects

No verified identity in a permissionless pool. Record on-chain identifiers and
expressly declare absence of identity attribution.

```
identifierType: ONCHAIN_ADDRESS
address:
accountType: EOA | SMART_ACCOUNT
controllers: []
attributedCluster:
attributionConfidence: HIGH | MEDIUM | LOW
inferredJurisdiction:
identityVerified: false
note: "No identity verification. Cluster attribution (if any) is from a
       commercial analytics provider and was not independently verified."
role: ORIGINATOR | BENEFICIARY | LINKED_WALLET
```

### B.3 Narrative fields (Who / What / When / Where / Why / How structure)

Objective drafting. No conclusions on lawfulness. No skill filenames.

| Field | Content |
|---|---|
| **DESCRIPTION (WHO / WHAT)** | Subject(s), instrument, observed operations in sequence with amounts/dates/txs |
| **ANALYSIS (WHEN / WHERE)** | Temporality and venue / path; concurrent typologies and indicators |
| **EVIDENCE (WHY)** | Why unusual: score, facts, profile contrast; supporting txs/emits |
| **CONCLUSION (HOW)** | Method of operation + control applied + reasonable-suspicion anchor. Not a filed SAR |

### B.4 Load warnings

| Warning | Content |
|---|---|
| Deadline | 30 calendar days from initial detection if operator is obligated |
| Confidentiality | Tip-off prohibition |
| Obligation determination | Filing depends on BSA qualification. Legal confirmation required |
| Document status | Support draft. Not submitted |

### B.5 Structured annex output (aligned with `OracleOpinion.sarAnnex`)

```json
{
  "produced": true,
  "status": "support-draft (not filed)",
  "activityPeriod": "<ISO 8601 or range>",
  "amountInvolved": "USD …",
  "operationState": "ALLOW | FEE_OVERRIDE | REVERT",
  "narrativeDescription": "WHO: … WHAT: …",
  "narrativeAnalysis": "WHEN: … WHERE: …",
  "narrativeEvidence": "WHY: …",
  "narrativeConclusion": "HOW: … Internal SAR-support pack. Not a FinCEN SAR.",
  "warnings": [
    "Confidentiality: no tip-off to the subject",
    "Document status: support draft. Not submitted",
    "Organize facts chronologically from the ledger for any human-owned filing",
    "Human judgment required before any BSA filing decision"
  ]
}
```

---

## C. Decision record

Brief document for decisions that do not require a full Opinion. Proves the
decision existed and had a basis.

```
DECISION RECORD
Event / Wallet / Pool / Block
Score: [XX]. Output: [ALLOW / FEE_OVERRIDE / REVERT]
Main facts: [top three by scoreContribution with regulatoryBasis]
Basis: [reason code]
Next review: [date]
auditHash: [...]
```

Maps to `OracleOpinion.decisionRecord`: `score`, `output`, `mainFacts`,
`basis`, `nextReview`.

---

## D. Pool aggregate report

Periodic product for the operator. Shows monitoring-system performance.
A supervisor examines this before individual cases.

```
MONITORING REPORT: POOL [0x...]
Period: [from] – [to]

1. VOLUME AND COVERAGE
2. OUTPUT DISTRIBUTION: ALLOW / FEE_OVERRIDE / REVERT / sanctions blocks
3. TYPOLOGIES DETECTED
4. REASONABLE-SUSPICION SIGNALS
5. OPERATIONAL PERFORMANCE: source availability, degraded mode, latency
6. FEE_OVERRIDE AND ESCROW: escrowed, released to pool, LP (liquidity provider) compensation
7. GOVERNANCE: Timelock parameter changes
8. TRACEABILITY: 5-year retention; auditHash index
```

---

## E. Authority-request compilation

If the operator receives an authority request, the agent compiles requested
material. It does not draft or send the response.

| Rule | Content |
|---|---|
| Scope | Only material the operator asks to compile |
| Recipient | Operator legal / Compliance Officer |
| Prohibition | Agent never answers any authority directly |
| Format | Case-file index with `auditHash`, on-chain events, sources. No legal interpretation |

---

## Pre-delivery review

- Opinion scoring matches `ScoreResult` and executed `hookOutput`
- Every conclusion has `regulatoryBasis` and identified on-chain evidence
- `LOW` confidence facts are labeled as such
- Analysis limits declared: hop depth, unavailable sources, gaps, degraded mode
- No conclusion on the lawfulness of a person’s conduct
- SAR annex status remains support-draft
- Evaluated subject was not tipped off
- No skill filenames in Opinion / annex sources
- Every corpus cite is a `normativeCitations[]` row with `id`, `publicationDate`, `retrievedAt` (from `search_regulations`); never from training memory

---

## Output (`OracleOpinion`: keys match `types.ts`)

```json
{
  "status": "Technical opinion · REVERT | Technical opinion · oracle FEE_OVERRIDE | Legal opinion · ALLOW",
  "documentType": "legal-opinion | opinion + sar-annex",
  "confidence": "HIGH | MEDIUM | LOW",
  "humanReview": false,
  "retentionYears": 5,
  "auditHash": "...",
  "technicalOpinion": {
    "issued": true,
    "objectAndScope": "<WHO>",
    "riskAndScoring": "<WHY>",
    "typologies": "<WHAT>",
    "sanctionsCheck": "<WHEN>",
    "sourcesConsulted": ["<WHERE: evidence only, no skill names>"],
    "decisionExecuted": "<HOW>",
    "legalBasis": "...",
    "recommendations": "...",
    "traceability": "auditHash … · calculated … · retention 5 years",
    "normativeCitations": [
      {
        "id": "<corpus id>",
        "title": "...",
        "framework": "FATF | OFAC | MICA | TFR | FINCEN | TREASURY | WOLFSBERG",
        "series": "...",
        "publicationDate": "YYYY-MM-DD",
        "retrievedAt": "<ISO 8601>",
        "sha256": "<pdf sha256>"
      }
    ]
  },
  "sarAnnex": { },
  "decisionRecord": {
    "score": "<finalScore>",
    "output": "ALLOW | FEE_OVERRIDE | REVERT",
    "mainFacts": "...",
    "basis": "...",
    "nextReview": "<ISO 8601>"
  },
  "note": "Internal operator documentation modeled on FinCEN SAR Narrative Guidance. Never filed with any authority."
}
```

> On `REVERT` or block activation, include the technical Opinion. When
> reasonable suspicion is also reached and the operator is a likely BSA
> obligated person, include the SAR-support annex.
