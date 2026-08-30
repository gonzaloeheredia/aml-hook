---
name: originator-attribution
description: "Determine who the real actor is behind the address reaching the hook when msg.sender is a router, aggregator, protocol contract, or Smart Account. Covers signed hookData reading, trusted-forwarder registry, subsidiary resolution methods, and fail-closed policy on failed attribution. Always use as the first domain skill, even before ofac-screening: without an attributed actor there is no subject for sanctions screening or profile building."
---

# Originator Attribution: Identifying the Real Actor

## Role

Determines the analysis subject.

In Uniswap v4, `msg.sender` reaching the hook is often a router. Scoring a
**trusted** router builds a risk profile of shared infrastructure, not of
an actor.

**This product (AML Hook today).** `hookData` is ignored. The hook already
resolved the subject before you run:

| Caller | Subject |
|---|---|
| Trusted forwarder (Anvil demo router; Sepolia Universal Router `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`) | Originator field (`SwapParams.msgSender` / LP (liquidity provider) equivalent). Never score the router. |
| Untrusted contract (Sepolia first mint: `PoolModifyLiquidityTest` `0x0C478023803a644c94c4CE1C1e7b9A087e411B0A`) | **That contract is the subject.** Same floors and oracle row as a user wallet. |
| Direct EOA (externally owned account) | That EOA |

Do not score PoolManager, AmlHook, AmlHookSatellite, oracle, or tokens.
Signed `hookData` below is the general model / future integrator path. It
is **not** what `beforeSwap` reads on this deploy.

That profile converges to the ecosystem average and never hits a useful
threshold (system detects nothing). If it did hit a threshold, it would block
every user of that router.

This skill runs before every other domain skill. Its output determines whether
an evaluable subject exists and, if so, which address.

---

## Governing principle: no attributable subject → no execution

An operation whose actor cannot be identified is functionally equivalent to
opening an anonymous safe-deposit box. No AML (Anti-Money Laundering)
framework admits that. Due diligence on an indeterminate subject is impossible
by definition. Recording “verified” on an unattributed operation produces a
false audit trail.

**AML Hook default policy is fail-closed.** If attribution does not resolve
with sufficient confidence, the swap reverts.

The only exception mechanism is the trusted-forwarder registry (Step 2). An
operator may configure a permissive policy, but that is an express operator
decision and is reported in the pool aggregate as monitoring coverage waived.

**Operational consequence.** Today no general-purpose router propagates the
originator with a verifiable signature. On an open pool, fail-closed without
registered forwarders reverts most flow. The model is viable on restricted /
RWA (real-world asset) pools where flow arrives via known integrators.
`protocol-obligations` must warn when configuring the pool.

**Demo runtime:** the UHI10 Anvil walkthrough attributes wallets A–E through
the trusted router / known demo identities. It does not exercise a live
signed-`hookData` path.

**Sepolia runtime:** this API (application programming interface) is not
pointed at `11155111`. A new EOA vs the live pool is use-case Wallet E until
a keeper writes. Consult `uhi10-sepolia` before treating an untrusted LP
router as “failed attribution”. It is a scored subject, not a missing
originator.

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
| **Smart Account** | Multisig / AA (account abstraction) interface | Attribute to the account; controller checks in `wallet-screening` |
| **Strategy contract** | Pooled third-party funds | Unresolvable; see Step 4 |
| **Unidentified contract** | No known attribution | Failed attribution |

An unrecognized router address is classified unidentified, not benign
infrastructure. Safe default: assume unknown.

---

## Step 2: Trusted-forwarder registry

Only mechanism that allows mediated flow without abandoning attribution.

### 2.1 Registration requirements (cumulative)

| Requirement | Content |
|---|---|
| Originator propagation | Includes end-user address in `hookData` |
| Verifiable signature | ECDSA (Elliptic Curve Digital Signature Algorithm) of a registered key, validatable by `SignatureVerifier` |
| Replay protection | Nonce and block/deadline so a signature cannot be reused |
| Operation binding | Signature covers at least originator, `poolId`, `amountSpecified`, `zeroForOne` |
| Declared responsibility | Integrator assumes accuracy of propagated data toward the pool operator |

### 2.2 Add / remove

Governable via DAO (decentralized autonomous organization) Timelock. Removals
take immediate effect on inbound flow and mark events attributed via a
later-revoked key for review.

### 2.3 Per-swap validation

1. `hookData` has expected structure
2. Signature valid against a current registry key
3. Nonce unused
4. Block/deadline not expired
5. Signed parameters match effective swap parameters

Any failure → failed attribution (not degraded), even if the sender is
registered, plus a risk fact against the forwarder.

---

## Step 3: Subsidiary methods

Only when the operator configured a non-restrictive policy, or for deferred
resolution of already-blocked events. Ordered by evidentiary value:

1. Signed `hookData` (even from non-registry sender; verify)
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
