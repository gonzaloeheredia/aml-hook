---
name: typology-detection
description: "Identify which documented AML/CFT typology the observed wallet behavior corresponds to, and anchor it in the FATF red-flag indicator that defines it. Translates technical on-chain findings into regulatory categories supervisors recognize. Use after wallet-screening and swap-behavior-analysis, before fact-scoring: converts technical evidence into normative basis."
---

# Typology Detection — AML/CFT Typology Identification

## Role

Answers: what is this called, in a supervisor’s vocabulary, that technical
analysis detected? Without this translation the case file has on-chain metrics
a regulator is not obliged to interpret. With it, it has recognized typologies
with reference red-flag indicators.

Does not produce score or decide hook output. Produces classification and
normative anchoring that `fact-scoring` incorporates into each triggering
fact’s `regulatoryBasis`.

---

## Expected inputs

| Field | Description |
|---|---|
| `walletScreeningOutput` | Result of `wallet-screening` |
| `swapBehaviorOutput` | Result of `swap-behavior-analysis` |
| `detectedPatterns` | Consolidated technical pattern list |
| `poolContext` | Pool type, asset pair, liquidity profile |

---

## Reference framework

FATF Virtual Assets Red Flag Indicators (2020) — six categories. Every
identified typology maps to at least one.

| Category | Content |
|---|---|
| **1** | Size and frequency of transactions |
| **2** | Transaction patterns |
| **3** | Anonymity |
| **4** | Sender / beneficiary profile |
| **5** | Source of funds |
| **6** | Geographic risks |

**Methodological principle.** A single indicator does not prove illicit
activity. Combination without economic explanation supports suspicion. Report
how many indicators/categories concur — that multiplicity underpins reasonable
suspicion (FATF Rec. 20).

---

## Step 1: Typology catalog

### 1.1 Fragmentation / structuring

| Typology | Definition | FATF | Required on-chain evidence |
|---|---|---|---|
| **Structuring** | Deliberate split below reporting thresholds | 1 | Series with cumulative sum ≥ threshold; none individually above; bounded window |
| **Smurfing** | Structuring across coordinated wallets | 1, 2 | Linked wallets (common funding / co-spend) + homogeneous sync pattern |
| **Threshold proximity** | Amounts clustered just below known threshold | 1 | Mode in 80–99% of threshold |

### 1.2 Layering / trail concealment

| Typology | FATF | Evidence |
|---|---|---|
| **Layering** | 2, 3 | High hop count, compressed intervals, no economic logic |
| **Chain-hopping** | 2, 3 | ≥3 networks in <24h before swap |
| **Peeling chain** | 1, 2 | Successive amount reduction across intermediate wallets |
| **Mixer use** | 3 | Documented interaction with mixing contract |
| **Post-mixer timing** | 3 | Swap inside configured post-mixer window |

### 1.3 Illicit source of funds

| Typology | FATF | Evidence |
|---|---|---|
| **Darknet funds** | 5 | Analytics cluster attribution |
| **Ransomware** | 5 | Addresses linked to ransomware schemes |
| **Exploit / protocol funds** | 5 | Traceable to documented exploit (demo: wallet A) |
| **N-hop contamination** | 5 | Closest-hop exposure from confirmed origin (`100 × 0.65^hops`) |

### 1.4 Native DeFi typologies

Flash-loan manipulation, sandwich extraction, wash trading, rug-pull LP
removal, ERC-6909 internal claims bypass, approval drain, address poisoning,
NFT layering, CEX chain-jump, investment-scam product patterns — map to Cats.
2/4/5 and DF fact types in `fact-scoring`.

**Receive vs use.** Address poisoning and unsolicited inbound tainted transfers
do not attribute conduct to the recipient without subsequent use.

---

## Step 2: Alternative hypothesis

Before confirming a typology:

1. State the legitimate economic explanation (if any)
2. Test against evidence
3. Retain or discard with recorded reason

If a legitimate explanation survives, degrade confidence or discard the fact
rather than force a typology label.

---

## Step 3: Multiplicity reporting

```json
{
  "typologies": [
    {
      "name": "N-hop contamination",
      "fatfCategories": [5],
      "confidence": "HIGH",
      "linkedFactTypes": ["HIGH_RISK_COUNTERPARTY", "RAPID_FULL_BALANCE_TRANSFER"],
      "regulatoryBasis": "FATF Rec. 10 · VA Red Flags Cat. 5"
    }
  ],
  "concurrentCategories": 1,
  "alternativeHypothesis": {
    "evaluated": true,
    "retained": false,
    "reason": "..."
  }
}
```

Report `concurrentCategories` count — feeds reasonable-suspicion and
sufficiency checks in `task-swap-decision`.
