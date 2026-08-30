---
name: ofac-screening
description: "Verify whether an address, its cluster, its controllers, or its counterparties are covered by international sanctions. Covers OFAC SDN (United States), UN Security Council lists, and EU consolidated lists, including designated smart contracts. Use on every wallet evaluation, with priority over any other analysis: a sanctions match is an unconditional override and stops the flow."
---

# OFAC Screening — Sanctions Verification

## Role

Verifies coincidence between an address and current sanctions lists. Classifies
the finding, determines true positive status, and activates the mandatory
action. Does not alone decide swap output: emits the override `FactEvent` and
routes to `task-blocking-protocol`.

Layer 1 of the hook architecture: fast, low gas, no external dependency at
swap runtime. On-chain designated-address mapping is consulted directly in
`beforeSwap`.

**Demo runtime:** the COA downloads the public OFAC SDN dump (ETH/EVM
addresses), screens the subject on every evaluation / Opinion, and on a
direct match writes `SanctionRegistry.setSanctioned`. Layer 1 at swap time
is still the mapping — `beforeSwap` does not call Treasury. Wallet A is
**not** on SDN; the agent writes score 100 from the exploit finding
(`WalletBlocked`). A live SDN exact-address match is hook Layer 1:
registry write and `SanctionHit`, not `WalletBlocked`, and not a use-case
wallet. A listed subject, P2P counterparty, or listed contract the wallet
used in the pool is score 100. Do not hop-contaminate B/C/D from a listed
address and do not fund E from one.

---

## Expected inputs

| Field | Description |
|---|---|
| `address` | Address under verification |
| `accountType` | From `wallet-screening` Step 1 (when available) |
| `controllers` | Controllers if Smart Account |
| `clusterName` | Entity attributed by analytics engine |
| `directCounterparties` | Addresses interacted with directly |
| `interactedContracts` | Contracts interacted with |
| `oracleResult` | On-chain designated-address mapping output |

---

## Step 1: Applicable lists

| List | Issuer | Scope |
|---|---|---|
| SDN List | OFAC — U.S. Treasury | Broad: USD, U.S. nexus, U.S. persons |
| Non-SDN sectoral (SSI, CAPTA, NS-MBS) | OFAC | Partial restrictions by program |
| Consolidated Sanctions List | UN Security Council | Universal |
| Consolidated List | European Union | Binding for EU-law entities / EU nexus |

**Addresses and contracts.** Since 2018 OFAC expressly lists virtual-asset
addresses. In Aug 2022 it designated an entire smart contract (Tornado Cash).
Screen both wallet and contract addresses.

---

## Step 2: Finding classification

| Category | Criterion |
|---|---|
| **Direct true positive** | Exact address on a current list |
| **Cluster true positive** | Analytics attributes address to a designated entity’s cluster |
| **Indirect exposure** | Interacted with a designated address without being listed |
| **False positive** | Superficial match discarded with explicit basis |

Exact address match is deterministic. Ambiguity arises in:

1. **Cluster attribution** — provider-dependent; max `confidence: MEDIUM`
   unless second independent source confirms.
2. **Smart Account controllers** — mapping a controller to a named designated
   person requires off-chain inference → human review.

Never discard a finding without recorded explicit basis.

---

## Step 3: Indirect exposure

Not a match, but not irrelevant. OFAC VC Industry Guidance (2021) expects
monitoring of indirect exposure. Emit NW/S facts such as
`INDIRECT_COUNTERPARTY_MATCH` (not automatic score-100 override unless policy
says so). Ceiling and weighting follow `fact-scoring`.

---

## Step 4: Mandatory action on direct match

| Finding | Fact type | Effect |
|---|---|---|
| Direct list match | `OFAC_DIRECT_MATCH` / `UN_DIRECT_MATCH` / `EU_DIRECT_MATCH` | Override `finalScore = 100`, `hookOutput = REVERT` |
| Designated contract interaction | `SANCTIONED_CONTRACT_DIRECT` | Same |
| TF / proliferation nexus | `TERRORISM_FINANCING` | Same, max urgency |
| Designated controller | controller hit | Preventive `REVERT` + human review |
| Cluster match | `SANCTIONED_CLUSTER_LINK` | `REVERT` + human review (not silent auto-clear) |

Stop the remaining domain flow. Route immediately to `task-blocking-protocol`.

---

## Structured output

```json
{
  "address": "0x...",
  "result": "CLEAR | DIRECT_MATCH | CLUSTER_MATCH | INDIRECT_EXPOSURE | CONTROLLER_MATCH",
  "list": "OFAC_SDN | UN | EU | null",
  "entryId": null,
  "confidence": "HIGH | MEDIUM | LOW",
  "facts": [
    {
      "type": "OFAC_DIRECT_MATCH",
      "dimension": "S",
      "baseWeight": 100,
      "confidence": "HIGH",
      "regulatoryBasis": "OFAC SDN · IEEPA · 31 CFR Part 501",
      "justification": "..."
    }
  ],
  "stopFlow": false,
  "nextSkill": "task-blocking-protocol | wallet-screening"
}
```
