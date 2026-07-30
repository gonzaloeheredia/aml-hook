---
name: protocol-obligations
description: "Determine which AML/CFT obligations fall on the operator of a pool integrating AML Hook under U.S. (BSA, OFAC) and EU (MiCA, TFR, AMLR) frameworks, and what evidence must be retained to demonstrate them. Use when configuring a new pool, reviewing the framework applicable to an operator, or determining the recipient and standard of the evidence pack."
---

# Protocol Obligations — Pool Operator Obligations

## Role

Answers the question prior to everything else: who bears the obligation. AML
Hook is not an obligated person. The hook is control infrastructure; the duty
falls, if at all, on the pool operator, the asset issuer, or the liquidity
provider entity — according to their own regulatory situation.

Produces the applicable-obligation map and corresponding evidence standard.
Does **not** issue binding legal opinions or alone determine obligated-person
status. That requires operator-specific legal advice in their jurisdiction.

---

## Expected inputs

| Field | Description |
|---|---|
| `operator` | Nature of the entity operating the pool |
| `operatorJurisdiction` | Incorporation / effective establishment |
| `userJurisdictions` | Jurisdictions from which the pool is accessed |
| `assetType` | Pair assets: stablecoin, tokenized RWA, native |
| `activeLicenses` | Operator registrations / authorizations |
| `degreeOfControl` | Effective control: parameters, pause, upgrade |

---

## Step 1: Obligated-person determination

Status depends on degree of control, not self-label. FATF VA guidance: an
actor with sufficient control/influence over the service may qualify as a
VASP even when presented as decentralized.

| Control indicator | Relevance |
|---|---|
| Ability to change pool parameters | High |
| Ability to pause / suspend | High |
| Ability to upgrade contracts | High |
| Fee capture on activity | High |
| Control of access interface | Medium |
| Maintenance of participant allowlist | High |
| Contractual relationship with participants | High |
| No operational control after deploy | Low |

**Mandatory warning.** Whether a DeFi protocol/operator is a BSA obligated
person is not uniformly settled. This skill produces a preliminary indicator
assessment and always declares that it does not replace specific legal analysis.

---

## Step 2: U.S. framework

### 2.1 Sanctions (OFAC)

Apply independent of BSA obligated status. U.S. persons / U.S.-nexus
transactions may not deal with designated parties. No minimum threshold; no
decentralization exception.

| Obligation | Content |
|---|---|
| Prohibition on dealing | No transaction with designated party |
| Blocking of property | Funds owed to designated party must be blocked, not returned |
| Segregation | Blocked asset kept segregated |
| Block report | To OFAC within 10 business days |
| Annual report | Annual blocked-property report |

### 2.2 BSA / FinCEN

If the operator is (or may be) a money services business / money transmitter:

- AML program, monitoring, SAR regime (31 CFR § 1010.320)
- Record retention
- Travel Rule for VASP-to-VASP transfers (31 CFR § 1010.410(e)–(f), USD 3,000)

**Travel Rule vs swap.** A pool swap does not meet Rec. 16 / Travel Rule
elements (no two institutions, no distinct originator/beneficiary, user keeps
custody). Functions of Travel Rule inside this system:

1. Mitigant on prior fund leg when IVMS 101 is verifiable
2. Operator’s own duty if offering custodial VASP services
3. Perimeter where compliance already exists

---

## Step 3: EU framework

| Instrument | Relevance |
|---|---|
| MiCA (EU) 2023/1114 | CASP authorization and conduct |
| TFR (EU) 2023/1113 | Crypto Travel Rule; zero threshold |
| AMLR (EU) 2024/1624 | Unified due diligence / monitoring |

Apply when operator or activity has EU nexus. Preliminary only.

---

## Step 4: Evidence standard for the Opinion pack

| Artifact | When | Retention |
|---|---|---|
| Technical Opinion | REVERT / block / reasonable suspicion; abbreviated on ALLOW | 5 years |
| SAR-support annex | Reasonable suspicion + likely BSA obligated status | 5 years |
| Decision records | All decisions including ALLOW | 5 years |
| Pool aggregate reports | Periodic | 5 years |

Recipient: operator Compliance Officer. Agent never files.

**Attribution coverage warning.** Fail-closed without trusted forwarders
reverts most open-pool flow; restricted/RWA pools with registered integrators
are the viable deployment model — disclose when configuring.

---

## Structured output

```json
{
  "preliminaryAssessment": {
    "likelyObligatedPerson": "unknown | possible | unlikely",
    "frameworks": ["OFAC", "BSA", "MiCA", "TFR", "AMLR"],
    "controlIndicators": [],
    "legalAdviceRequired": true
  },
  "travelRule": {
    "appliesToSwap": false,
    "rolesInSystem": ["prior_leg_mitigant", "custodial_vasp_duty", "perimeter"]
  },
  "evidenceStandard": {
    "retentionYears": 5,
    "opinionRecipient": "pool_compliance_officer",
    "agentFilesWithAuthorities": false
  },
  "deploymentWarnings": [
    "Fail-closed attribution without trusted forwarders reverts most open-pool flow"
  ],
  "disclaimer": "Preliminary indicator assessment only. Not a legal determination of obligated-person status."
}
```
