---
name: wallet-screening
description: "Evaluate AML/CFT risk of an address participating in a Uniswap v4 swap. Covers blockchain analytics, direct and indirect exposure to risk entities, cluster attribution, obfuscation patterns (mixing, bridging, chain-hopping, peeling), and account-type classification. Use as the primary domain skill in every case: base analysis unit for the wallet profile."
---

# Wallet Screening: Address Risk Evaluation

## Role

AML/CFT (Anti-Money Laundering / Combating the Financing of Terrorism)
analysis unit on an individual address. Does not decide swap output:
evaluates, documents, and produces `FactEvent`s that `fact-scoring` quantifies.

Assumed production stack: Chainalysis, Elliptic, or TRM Labs. Must function in
degraded mode when the commercial provider fails, relying on explorer and
indexed public sources.

**Demo runtime:** those HTTP/vendor feeds are not called. Screening facts come
from the A–D memory ledger, `SanctionRegistry`, and skill `uhi10-use-case`.

Operates exclusively on `addressToEvaluate` from `originator-attribution`.
If attribution failed, this skill does not run.

---

## Expected inputs

| Field | Description |
|---|---|
| `address` | Address under analysis |
| `swapRole` | `SENDER` (beforeSwap) or `RECIPIENT` (afterSwap) |
| `chainId` | Pool network |
| `poolId` | Uniswap v4 pool id |
| `currencyIn` / `currencyOut` | Pair token addresses |
| `amountSpecified` | Swap amount as seen by the hook |
| `analyticsResult` | Analytics engine output, if available |
| `priorScore` | Last oracle `ScoreResult`, if any |

---

## Step 1: Account-type classification

| Type | Detection | Implication |
|---|---|---|
| **EOA (externally owned account)** | `EXTCODESIZE == 0` | Direct analysis |
| **Smart Account / Multisig** | Code + Safe / ERC-4337 pattern | Controller verification (Step 2) |
| **Protocol contract** | Known protocol attribution | Risk on real originator, not router |
| **Router / aggregator** | Universal Router, 1inch, CoW, etc. | Not the subject. Attribution must already have resolved |
| **Undetermined** | No attribution possible | Analyze as EOA; record indeterminacy |

**Critical rule.** Evaluating the router as the subject has no AML value.

---

## Step 2: Smart Account verification

### 2.1 Controllers
Evaluate each owner against S and NW. Sanctions match on a controller →
account inherits override path.

### 2.2 Threshold
A compromised controller does not always imply execution power. If clean
controllers still meet the multisig threshold, note that, **except** for
`OFAC_DIRECT_MATCH` on a controller: designation reaches entities where the
designated person has relevant participation; escalate to human review with
preventive `REVERT`.

### 2.3 Preregistration mitigant
Institutional Smart Accounts with completed controller verification within
validity window may emit `PREREGISTERED_SMART_ACCOUNT` (MT).

---

## Step 3: Exposure and obfuscation

Assess and emit facts for:

- Direct / indirect sanctions exposure (feeds `ofac-screening` findings)
- Mixer / privacy infrastructure (MX)
- Chain-hopping / peeling / rapid full-balance moves (NW)
- Darknet / ransomware / exploit-fund links (NW)
- Opaque majority origin (MX)

**Receive vs use.** Unsolicited inbound contamination is not attributable
conduct. Only subsequent movement/use counts.

---

## Step 4: Cluster attribution

Cite as provider judgment. Max confidence `MEDIUM` unless second independent
source. On provider disagreement, report both. Do not select one source.

---

## Structured output

```json
{
  "address": "0x...",
  "accountType": "EOA | SMART_ACCOUNT | PROTOCOL | ROUTER | UNDETERMINED",
  "controllers": [],
  "facts": [
    {
      "type": "...",
      "dimension": "S | ST | MX | NW | GEO | MT | DF",
      "baseWeight": 0,
      "confidence": "HIGH | MEDIUM | LOW",
      "regulatoryBasis": "...",
      "justification": "..."
    }
  ],
  "analyticsProvider": null,
  "degradedMode": false,
  "limitations": []
}
```
