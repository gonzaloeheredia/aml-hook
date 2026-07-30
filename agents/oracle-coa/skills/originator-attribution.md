---
name: originator-attribution
description: "Determine who the real actor is behind the address reaching the hook when msg.sender is a router, aggregator, protocol contract, or Smart Account. Covers signed hookData reading, trusted-forwarder registry, subsidiary resolution methods, and fail-closed policy on failed attribution. Always use as the first domain skill, even before ofac-screening: without an attributed actor there is no subject for sanctions screening or profile building."
---

# Originator Attribution — Identifying the Real Actor

## Role

Answers the question that conditions everything else: who is the analysis about?

In Uniswap v4, `msg.sender` reaching the hook is rarely the user’s wallet.
Most swaps arrive via Universal Router, aggregators, strategy contracts, or
Smart Accounts. Scoring that address builds a risk profile of shared
infrastructure used by millions of operations — not of an actor.

That profile converges to the ecosystem average and never hits a useful
threshold (system detects nothing). If somehow it did, it would block every
user of that router indiscriminately.

This skill runs before every other domain skill. Its output determines whether
an evaluable subject exists and, if so, which address.

---

## Governing principle: no attributable subject → no execution

An operation whose actor cannot be identified is functionally equivalent to
opening an anonymous safe-deposit box. No AML framework admits that. Due
diligence on an indeterminate subject is impossible by definition; recording
“verified” on an unattributed operation produces a false audit trail — worse
than none.

**AML Hook default policy is fail-closed.** If attribution does not resolve
with sufficient confidence, the swap reverts.

The only exception mechanism is the trusted-forwarder registry (Step 2). An
operator may configure a permissive policy, but that is an express operator
decision and is reported in the pool aggregate as monitoring coverage waived.

**Operational consequence.** Today no general-purpose router propagates the
originator with a verifiable signature. On an open pool, fail-closed without
registered forwarders reverts most flow. The model is viable on restricted /
RWA pools where flow arrives via known integrators. `protocol-obligations`
must warn when configuring the pool.

---

## Expected inputs

| Field | Description |
|---|---|
| `msgSender` | Address the hook receives as sender |
| `hookData` | Swap `hookData` payload |
| `txHash` | Transaction containing the swap |
| `txOrigin` | Transaction origin address |
| `poolId` | Involved pool |
| `forwarderRegistry` | Pool’s enabled routers / integrators |
| `traceAvailable` | Whether the node exposes transaction trace |

---

## Step 1: Classify msg.sender

| Class | Detection | Treatment |
|---|---|---|
| **Direct EOA** | `EXTCODESIZE == 0` and `msgSender == txOrigin` | Direct attribution |
| **Trusted forwarder** | Address in pool registry | Resolve via signed `hookData` |
| **Unregistered router/aggregator** | Infrastructure outside registry | Failed attribution unless valid signed `hookData` |
| **Smart Account** | Multisig / AA interface | Attribute to the account; controller checks in `wallet-screening` |
| **Strategy contract** | Pooled third-party funds | Unresolvable; see Step 4 |
| **Unidentified contract** | No known attribution | Failed attribution |

An unrecognized router address is classified unidentified — not benign
infrastructure. Safe default: assume unknown.

---

## Step 2: Trusted-forwarder registry

Only mechanism that allows mediated flow without abandoning attribution.

### 2.1 Registration requirements (cumulative)

| Requirement | Content |
|---|---|
| Originator propagation | Includes end-user address in `hookData` |
| Verifiable signature | ECDSA of a registered key, validatable by `SignatureVerifier` |
| Replay protection | Nonce and block/deadline so a signature cannot be reused |
| Operation binding | Signature covers at least originator, `poolId`, `amountSpecified`, `zeroForOne` |
| Declared responsibility | Integrator assumes accuracy of propagated data toward the pool operator |

### 2.2 Add / remove

Governable via DAO Timelock. Removals take immediate effect on inbound flow
and mark events attributed via a later-revoked key for review.

### 2.3 Per-swap validation

1. `hookData` has expected structure
2. Signature valid against a current registry key
3. Nonce unused
4. Block/deadline not expired
5. Signed parameters match effective swap parameters

Any failure → failed attribution (not degraded), even if the sender is
registered — plus a risk fact against the forwarder.

---

## Step 3: Subsidiary methods

Only when the operator configured a non-restrictive policy, or for deferred
resolution of already-blocked events. Ordered by evidentiary value:

1. Signed `hookData` (even from non-registry sender — verify carefully)
2. Transaction trace (`tx.origin` / call chain) when node exposes it
3. Deterministic co-spend / funding graph (deferred, high latency)

Never build a profile on the router itself.

---

## Step 4: Failed attribution

Under **restrictive** policy (default): `hookOutput = REVERT`, reason
`ATTRIBUTION_FAILED`. No domain analysis. Optionally enqueue
`DEFERRED_ATTRIBUTION` if enabled.

Under deferred / elevated / permissive policies: record waived coverage and
apply the operator’s documented fallback (still never invent a subject).

---

## Structured output

```json
{
  "resolved": true,
  "addressToEvaluate": "0x...",
  "msgSender": "0x...",
  "method": "direct_eoa | trusted_forwarder | signed_hook_data | trace | failed",
  "confidence": "HIGH | MEDIUM | LOW",
  "policyApplied": "restrictive | deferred | elevated | permissive",
  "hookOutputIfFailed": "REVERT",
  "reasonCode": "ATTRIBUTION_FAILED | null",
  "forwarder": null,
  "notes": "..."
}
```
