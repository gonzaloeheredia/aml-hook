# AML HOOK

Modular Compliance Layer for Uniswap v4

Use Case — Exploit Detection, Propagation and N-Hop Decay

## 1. Overview

AML Hook is a compliance layer deployed natively as a Uniswap v4 hook. On swaps it intercepts beforeSwap and afterSwap, applies a ternary risk decision, and emits a structured on-chain event that constitutes the operator's audit trail. The hook operates without interrupting the normal swap execution path for clean addresses.

This use case is swap-only. Independently, a sanctioned wallet that attempts to add or remove liquidity is reverted at beforeAddLiquidity / beforeRemoveLiquidity (SanctionRegistry only — no score, no RiskPolicy). The LP position is not transferred or confiscated; once the sanction is lifted, the same withdrawal succeeds with no extra step.

This document describes a four-wallet scenario that exercises all three decision outputs of the hook, plus the oracle-latency inflow heuristic and the never-scored **USD** magnitude bands: full block (revert), FEE_OVERRIDE with punitive total friction (pool standard fee + FeeEscrow differential), FEE_OVERRIDE with proportional friction, FEE_OVERRIDE under a stale scored-clean inflow (Wallet D), and Wallet E — a brand-new wallet (`updatedAt == 0`) whose first flow is quoted to USD via Chainlink (under $1,000 → 3%; $1,000–$24,999 → 8%; ≥ $25,000 or structured window USD → `UnscoredMagnitudeBlocked`; missing/stale feed → `MagnitudeQuoteFailed`). The scenario is grounded in an exploit cash-out attack, two-hop fund propagation through intermediary wallets, a third path that swaps inside the keeper's processing window, and a brand-new wallet with no oracle row.

### Actors

```text
----------- -------------------------------------------------------------------------------------------------------------------------- -------------------------
Wallet      Role                                                                                                                       Initial Score

Wallet A    Exploit attacker. Drains an external lending protocol and attempts to use the pool to convert stolen USDC into ETH.        100 (exploit confirmed)

Wallet B    Starts clean (same rules as C). Receives from A → 1-hop (~65). Receives from tainted C → 2-hop (~42). Closer hop wins.     0 (clean)

Wallet C    Starts clean (same rules as B). Receives from A → 1-hop (~65). Receives from tainted B → 2-hop (~42). Closer hop wins.     0 (clean)

Wallet D    Fourth actor. Previously published clean (score 0, non-zero updatedAt). Receives a direct P2P transfer from Wallet A          0 (published clean)
            seconds before attempting a swap, before the keeper has processed that transfer. This is Mitigation D, not "unknown".

Wallet E    Fifth actor. Brand-new wallet: oracle `updatedAt == 0` (never written). No inflow baseline. First-swap USD bands:               — (never written)
            under $1,000 → 3%; $1,000–$24,999 → 8%; ≥ $25,000 (or window USD) → REVERT
            (`UnscoredMagnitudeBlocked`). Missing/stale Chainlink feed fail-closes. Not Wallet D.
----------- -------------------------------------------------------------------------------------------------------------------------- -------------------------
```

The walkthrough below uses one propagation path (A → B → C) to exercise all three hook outputs in a single run, then a third path (A → D) that isolates the causal latency gap from whitepaper section 3.8 (scored-clean + inflow), then Wallet E for a never-scored large first swap. The scoring engine treats B and C symmetrically for any P2P path. D has a keeper write in its past; E does not.

The pool is configured as a Real World Asset (RWA) pool on Uniswap v4, with AML Hook attached (beforeSwap, afterSwap, afterSwapReturnDelta, beforeAddLiquidity, beforeRemoveLiquidity). The off-chain scoring keeper monitors transfer events continuously and, on the A → B → C path, writes updated scores on-chain before the corresponding swap is attempted. The A → D path deliberately places the swap inside the window before that write lands. Call path, AccessManager roles, and FeeEscrow settlement are specified in the whitepaper (sections 3.5 and 3.7).

## 2. Risk Scoring Model

### 2.1 Ternary Decision Logic

```text
------------- -------------------------------------------------- ------------------- ----------------------------------------------------------------------------------------------------------------------------------
Score Range   Hook Response                                      Fee Applied         Regulatory Basis

0 – 30        Allow                                              Standard (0.30%)    No risk indicators. Normal execution.

31 – 70       Allow with FEE_OVERRIDE (pool standard fee + differential → FeeEscrow)   Dynamic (3% – 8% total friction)   Suspected contamination, not yet confirmed. Enhanced Due Diligence (EDD) equivalent. The swap still executes; friction is the escrowed differential, distinct from REVERT (which denies the swap in beforeSwap).

71 – 100      Revert                                             N/A                 Confirmed exposure: exploit cluster, OFAC match, or direct link to sanctioned entity. No discretion.

Never written (`updatedAt == 0`), assessed USD < $1,000   FEE_OVERRIDE (Mitigation A)   3%   Unknown ≠ clean. Wallet E dust / CDD-aligned band.

Never written, $1,000 ≤ assessed USD < $25,000   FEE_OVERRIDE (Mitigation A mid)   8%   Unknown, economically material first flow.

Never written, this swap + window USD ≥ $25,000   Revert (`UnscoredMagnitudeBlocked`)   N/A   Unknown + large or structured first flow. Not a score-band block.

Never written, no / stale price feed   Revert (`MagnitudeQuoteFailed`)   N/A   Fail-closed. Same posture as a missing sanctions read.
------------- -------------------------------------------------- ------------------- ----------------------------------------------------------------------------------------------------------------------------------
```

### 2.2 N-Hop Decay Formula

Contamination from a tainted source propagates to downstream wallets with a mathematically decreasing weight.

The formula applied by the off-chain keeper is:

```
derived_score = origin_score × (decay_factor ^ hops) × exposed_proportion
```

```text
-------------------- --------------------- ---------------------------------------------------------------------------------------------------------------
Parameter            Value Used            Description

decay_factor         0.65                  Contamination weight retained per hop. Industry-aligned: meaningful signal up to 3 hops, negligible beyond 4.

exposed_proportion   1.0 (full transfer)   Fraction of the receiving wallet's balance that originates from the tainted source.

origin_score         100 (Wallet A)        Score of the originating tainted wallet, as written by the keeper after exploit detection.
-------------------- --------------------- ---------------------------------------------------------------------------------------------------------------
```

Calculated scores for this scenario:

```text
---------------------------- ------------------ ---------------------------------------------- ----------------- -----------------------
Wallet                       Hops from Source   Calculation                                    Resulting Score   Hook Tier

A                            0 (source)         Detected directly via on-chain exploit event   100               Revert

B                            1                  100 × 0.65¹ × 1.0 = 65                         65                Punitive fee (8%)

C (after receiving from B)   2                  100 × 0.65² × 1.0 = 42                         42                Proportional fee (3%)
---------------------------- ------------------ ---------------------------------------------- ----------------- -----------------------
```

## 3. Full Execution Sequence

#### Step 0 — Baseline: Clean Swap (Wallet C, pre-contamination)

Before any exploit occurs, Wallet C executes a standard RWA swap in the pool. At this point C has no risk history.

```text
--------------------------- ---------------------------------------------------------------------------------
Event                       Detail

Actor                       Wallet C

Action                      Swap USDC → RWA token at standard pool conditions.

beforeSwap — Layer 1        OFAC screening: no match.

beforeSwap — Score read     Keeper score: 0. Below 30 threshold. No fee override applied.

Execution                   Swap executes at standard fee (0.30%).

afterSwap — Event emitted   { address: C, score: 0, decision: ALLOW, fee: 0.30%, amount: X, timestamp: T0 }

Hook output                 ALLOW — standard fee. No friction for legitimate operators.
--------------------------- ---------------------------------------------------------------------------------
```

#### Step 1 — Exploit Detection: Direct Attack (Wallet A)

Wallet A executes an exploit against an external lending protocol, extracting $10M USDC. The attacker immediately attempts to swap those funds in the AML Hook pool to convert them into ETH before Circle freezes the USDC address.

The off-chain keeper monitors transfer events and mempool activity. It detects the exploit event on-chain, traces the USDC outflow to Wallet A, and writes score 100 before the swap transaction is confirmed.

```text
------------------------- -------------------------------------------------------------------------------
Event                     Detail

Actor                     Wallet A

Action                    Swap $10M USDC → ETH.

Keeper — prior to swap    Exploit event detected on-chain. Score 100 written to oracle for Wallet A.

beforeSwap — Layer 1      OFAC screening: no match (designation lag, list not yet updated).

beforeSwap — Score read   Keeper score: 100. Threshold 71 exceeded. revert() executed atomically.

Execution                 Transaction reverts. No funds move. No liquidity provider (LP) exposure.

afterSwap                 Not reached. Revert occurs in beforeSwap.

Hook output               REVERT — exploit cluster confirmed. Block precedes OFAC designation by hours.
------------------------- -------------------------------------------------------------------------------
```

#### Step 2 — First-Hop Propagation: Wallet A → Wallet B (P2P Transfer)

Blocked at the pool, Wallet A routes the stolen funds via a peer-to-peer transfer directly to Wallet B, an intermediary address with no prior risk history. The transfer occurs outside the Automated Market Maker (AMM), at the ERC-20 token level.

The keeper detects the inbound transfer to Wallet B, traces its origin to Wallet A (score 100), and applies the decay formula: 100 × 0.65¹ × 1.0 = 65. Score 65 is written to the oracle for Wallet B before any swap is attempted.

#### Step 3 — First-Hop Swap Attempt (Wallet B, Score 65)

```text
--------------------------- ---------------------------------------------------------------------------------------------------------------
Event                       Detail

Actor                       Wallet B

Action                      Attempts to swap USDC → ETH in the AML Hook pool.

beforeSwap — Layer 1        OFAC screening: no match.

beforeSwap — Score read     Keeper score: 65. Falls in tier 31–70. No revert. Pool keeps standard fee; afterSwap takes differential into FeeEscrow (~8% total intended friction).

Execution                   Swap executes. Pool keeps standard fee; risk differential (~8% total intended friction minus standard) deposited into FeeEscrow (48h hold). User output settles in-block; net proceeds to Wallet B reduced.

afterSwap — Event emitted   { address: B, score: 65, decision: FEE_OVERRIDE, fee: 8.00%, hop_distance: 1, origin: A, timestamp: T2 }

Hook output                 PUNITIVE FEE — direct contamination from exploit source. Economic penalty applied. Full audit trail recorded.
--------------------------- ---------------------------------------------------------------------------------------------------------------
```

#### Step 4 — Second-Hop Propagation: Wallet B → Wallet C (P2P Transfer)

Wallet B transfers a portion of the remaining funds to Wallet C. The keeper detects the transfer, traces the contamination chain (A → B → C), and calculates the two-hop score: 100 × 0.65² × 1.0 = 42. Score 42 is written to the oracle for Wallet C, overwriting the prior clean score of 0.

#### Step 5 — Second-Hop Swap Attempt (Wallet C, Score 42)

```text
--------------------------- ----------------------------------------------------------------------------------------------------------
Event                       Detail

Actor                       Wallet C

Action                      Attempts to swap USDC → ETH in the AML Hook pool.

beforeSwap — Layer 1        OFAC screening: no match.

beforeSwap — Score read     Keeper score: 42. Falls in tier 31–70. Pool keeps standard fee; afterSwap takes differential into FeeEscrow (~3% total intended friction, proportional to lower contamination).

Execution                   Swap executes. Pool keeps standard fee; risk differential (~3% total intended friction minus standard) deposited into FeeEscrow (48h hold). User output settles in-block; fee reflects two-hop distance.

afterSwap — Event emitted   { address: C, score: 42, decision: FEE_OVERRIDE, fee: 3.00%, hop_distance: 2, origin: A, timestamp: T4 }

Hook output                 PROPORTIONAL FEE — two-hop contamination. Penalty decays with distance. Audit trail maintained.
--------------------------- ----------------------------------------------------------------------------------------------------------
```


## 3.1 Fee Escrow on FEE_OVERRIDE Paths (Steps 3 and 5)

On every FEE_OVERRIDE settlement (Wallet B at ~8 percent total friction, Wallet C at ~3 percent), the pool keeps its standard LP fee. Only the risk differential is taken in afterSwap and deposited into FeeEscrow. If deposit fails after that take, the swap still settles: the hook emits RiskFeeSkipped with DEPOSIT_FAILED, credits failedDeposits[wallet][token], and returns hookDelta. The subject can claimFailedDeposit(token), or anyone can retryEscrowDeposit(wallet, token) once escrow accepts deposits again. Other skip reasons (ZERO_BASIS, FEE_TOKEN_NOT_ALLOWED) emit RiskFeeSkipped and take nothing. User swap output settles in the same block; the escrow never retains the full swap.

Deposit records wallet, amount, timestamp and origin transaction hash (FeeDeposited).

There are two COA consultations on the escrow path; the FeeEscrow keeper alone submits the on-chain transfer after an off-chain sanity check on the COA output:

```text
-------------------- ----------------------- -------------------------------------------------------------- --------------------------------
Moment               COA / keeper action     On-chain call                                                  Destination of retained fee
-------------------- ----------------------- -------------------------------------------------------------- --------------------------------
0–24h                Optional COA review     None (fee stays in FeeEscrow)                                  Still held
Checkpoint 1         First COA consult +     releaseEarly → FeeReleasedEarly                                lpCompensationFund
(≥24h, <48h)         keeper sanity check                                                                    (never the pool). Never blocks.
Checkpoint 2         Second COA consult +    resolveCheckpoint2(illicitConfirmed)                           Illicit → Blocked (tokens stay
(≥48h)               keeper sanity check     → FeeBlocked or FeeReleasedDefault                             in FeeEscrow).
                                                                                                            Not illicit → lpCompensationFund
                                                                                                            (never the pool).
No resolution by 48h —                       releaseDefault → FeeReleasedDefault                            lpCompensationFund
                                                                                                            (never the pool).
-------------------- ----------------------- -------------------------------------------------------------- --------------------------------
```

Events FeeReleasedEarly, FeeBlocked and FeeReleasedDefault complete the audit trail for the operator.

## 4. Sequence Summary

```text
------ -------- ---------------------------------------------------------------- ------- ----------------------------- -------
Step   Actor    Action                                                           Score   Hook Decision                 Fee

0      C        Standard swap (pre-contamination)                                0       ALLOW                         0.30%

1      A        Direct swap attempt with exploit funds                           100     REVERT                        N/A

2      A → B    P2P transfer outside pool. Keeper writes score 65 to Wallet B.   —       Off-chain keeper update       —

3      B        Swap attempt with 1-hop contaminated funds                       65      FEE OVERRIDE (punitive)       8.00% -> FeeEscrow

4      B → C    P2P transfer outside pool. Keeper writes score 42 to Wallet C.   —       Off-chain keeper update       —

5      C        Swap attempt with 2-hop contaminated funds                       42      FEE OVERRIDE (proportional)   3.00% -> FeeEscrow

6      A → D    P2P transfer; keeper updateScore for D not yet confirmed         —       Off-chain (pending)           —

7      D        Swap under stale score 0; inflow heuristic elevates              0       FEE OVERRIDE (inflow)         8.00%

8      —        Keeper catch-up: writes decay score 65 for Wallet D              65      Off-chain keeper update       —

E-a    E        First swap under $1,000; never written (`updatedAt == 0`)        —       FEE OVERRIDE (Mitigation A)   3.00%

E-a2   E        First swap $1,000–$24,999                                        —       FEE OVERRIDE (Mitigation A mid) 8.00%

E-b    E        First swap or window USD ≥ $25,000                               —       REVERT (`UnscoredMagnitudeBlocked`) N/A
------ -------- ---------------------------------------------------------------- ------- ----------------------------- -------
```

## 5. On-Chain Audit Trail

Successful swaps emit a structured event via afterSwap (`SwapObserved`). These events are indexed by The Graph and constitute the immutable audit record that the pool operator presents to regulators (Financial Crimes Enforcement Network, FinCEN; Markets in Crypto-Assets Regulation, MiCA; Office of Foreign Assets Control, OFAC) to demonstrate transaction-level due diligence. They also serve as the factual input for any Suspicious Transaction Report (STR) filed by the operator's compliance function. Reverted attempts do not keep those logs — index the custom errors below.

Each event record contains:

-   The wallet address screened.

-   The risk score at the time of the swap.

-   The decision taken (ALLOW, FEE_OVERRIDE, or REVERT).

-   The fee applied, or the revert basis.

-   The hop distance from the contamination source, where applicable.

-   The origin wallet traced as the contamination source.

-   The transaction amount and timestamp.

Successful swaps emit `SwapObserved` (and `LatencyMitigationApplied` / `InflowHeuristicTriggered` when a floor applied). Reverted swaps do **not** keep those logs. Off-chain monitors must index custom errors on failed transactions:

| Error | Cause |
|---|---|
| `SanctionHit` | Layer 1 list |
| `WalletBlocked` | Score ≥ 71 |
| `UnscoredMagnitudeBlocked` | `updatedAt == 0` and assessed USD-8 ≥ `unscoredRevertThreshold` ($25,000 default) |
| `InflowMagnitudeBlocked` | Published score, inbound USD-8 since baseline ≥ `unscoredRevertThreshold` (Mitigation D absolute) |
| `MagnitudeQuoteFailed` | Never-scored (or D inflow) and Chainlink feed missing, stale, or invalid — fail-closed |

No existing compliance hook on Uniswap v4 produces this record. Binary allowlist models either permit or block, and emit no structured data on the decision rationale.

## 6. Regulatory Basis

```text
------------------------------------ ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Hook Behavior                        Regulatory Principle

Score 71–100: unconditional revert   OFAC mandatory blocking obligation. Financial Action Task Force (FATF) Recommendation 6: targeted financial sanctions, no discretion.

Score 31–70: FEE_OVERRIDE + FeeEscrow   FATF Recommendation 10: Enhanced Due Diligence for higher-risk situations. Risk-based approach: not all risk justifies a block; friction and monitoring are the appropriate response at intermediate risk. Settlement is pool standard fee plus escrowed differential, not a punitive lpFeeOverride to LPs.

N-hop decay scoring                  FATF Virtual Assets Red Flag Indicators (2020): indirect exposure to illicit funds constitutes a risk indicator. The system must trace fund origin, not just direct counterparty.

Immutable on-chain event log         FATF Recommendation 11: record retention, minimum five years. The audit trail is on-chain and non-modifiable.
------------------------------------ ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

## 7. Latency Mitigation Scenario: Wallet D

This scenario isolates the causal latency gap described in section 3.8 of the whitepaper. Unlike the A, B, C sequence, where the keeper writes each score before the corresponding swap is attempted, this scenario places the swap attempt inside the window during which the keeper has not yet processed the inbound transfer.

#### Step 6 — Third Propagation Path: Wallet A → Wallet D (P2P Transfer), Immediate Swap Attempt

```text
----------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------
Event                   Detail

Actor                   Wallet A → Wallet D

Action                  Wallet A transfers the tainted funds directly to Wallet D, outside the AMM (Automated Market Maker), at the ERC-20 (Ethereum Request for Comments 20)
                        token level.

Keeper status           The transfer is detected by the off-chain monitor but the updateScore transaction for Wallet D has not yet been confirmed on-chain.

Elapsed time            Approximately 8 seconds between the transfer's confirmation and Wallet D submitting a swap.

Oracle state at swap    ComplianceOracle still holds Wallet D's **published** score: 0, with a non-zero updatedAt that predates the transfer. This is not a never-written wallet. Mitigation D can fire; Mitigation A's magnitude REVERT does not.
----------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------
```

#### Step 7 — Swap Attempt Under a Stale Score (Wallet D)

```text
----------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------
Event                   Detail

Actor                   Wallet D

Action                  Attempts to swap USDC into ETH in the AML Hook pool.

beforeSwap, Layer 1     OFAC (Office of Foreign Assets Control) screening: no match.

beforeSwap, Layer 2     Keeper score: 0. Read in isolation, this would resolve to ALLOW.
score read

beforeSwap, balance     The hook queries token.balanceOf(D). lastKnownBalance[D] was 0. currentBalance equals the full transferred amount. deltaBps equals 10000 (100 percent of
heuristic               current balance), exceeding the configured inflowThresholdBps of 5000. The inflow timestamp postdates the oracle's updatedAt for Wallet D, so the stored
                        score of 0 does not yet reflect this transfer.

RiskPolicy decision     hasSignificantInflow resolves to true. The floor described in the mitigation forces a minimum output of FEE_OVERRIDE, overriding what the stale score of
                        0 would otherwise permit. No keeper-recommended feeBps is available yet, so the desired product behavior applies the intermediate latency fee of 8 percent.

Execution               Swap executes. Pool keeps the standard 0.30 percent LP fee; the 8 percent total intended friction is that base plus the risk differential deposited into FeeEscrow. User output settles in-block. Economic friction is applied despite a stored score that has not yet incorporated the
                        inflow.

afterSwap, event        address: D, score: 0 (stale), decision: FEE_OVERRIDE, fee: 8.00 percent, trigger: InflowHeuristicTriggered, deltaBps: 10000, timestamp: T5. hop_distance
emitted                 and origin are not populated, because the heuristic detects the pattern, not the source.

Hook output             FEE_OVERRIDE by inflow heuristic. The gap between the transfer and the keeper's update did not translate into an unconditioned swap.
----------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------
```

#### Step 8 — Keeper Catch-Up

Shortly after Step 7, the keeper processes the A to D transfer and writes Wallet D's decay-based score: 100 times 0.65 to the first power, equaling 65, one hop from Wallet A. From this point forward, Wallet D's swaps are evaluated against that score rather than against the inflow heuristic, which only governs the window before the keeper catches up.

### Comparison: With and Without the Heuristic

```text
----------------------------------------------------------- ------------------- ------------
Condition                                                   Hook Output         Fee

Without inflow heuristic (score read alone)                 ALLOW               0.30 percent

With inflow heuristic (Step 7, as designed)                 FEE_OVERRIDE        8.00 percent
----------------------------------------------------------- ------------------- ------------
```

### Stated Limitation

The heuristic identifies a behavioral pattern, a large inflow immediately followed by a swap attempt, not the origin of the funds. It cannot distinguish a transfer from a tainted wallet from a legitimate large deposit, such as a withdrawal from a centralized exchange. A wallet with a genuinely clean funding source that happens to deposit a large balance and swap immediately will incur the same intermediate fee. This is an accepted false positive cost, applied only within the narrow window before the keeper writes an updated score, and it is not a determination of guilt, only a temporary friction pending confirmation.

A never-written wallet (`updatedAt == 0`) is **not** this path. Mitigation D is skipped without a score and without a baseline, so a first swap is not treated as a 100 percent inflow. That wallet is section 7.1.

## 7.1 Never-scored magnitude: Wallet E

Wallet E has no ComplianceOracle row. `updatedAt` is 0. There is no `lastKnownBalance` baseline.

```text
----------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------
Event                   Detail

Small first swap        Assessed USD below $1,000 (unscoredFeeThreshold = 1_000e8).
                        Mitigation A: FEE_OVERRIDE at 3 percent. InflowHeuristicTriggered is not emitted.

Mid first swap          Assessed USD from $1,000 up to but not including $25,000.
                        Mitigation A mid: FEE_OVERRIDE at 8 percent.

Large first swap        Assessed USD ≥ $25,000 (unscoredRevertThreshold = 25_000e8).
                        RiskPolicy REVERT. beforeSwap reverts `UnscoredMagnitudeBlocked(E, assessedUsd, threshold)`.
                        Distinct from Wallet A (`WalletBlocked`, score 100) and from a sanction (`SanctionHit`).

Structuring             Never-scored swaps whose USD-8 window sum (quoted at each afterSwap) plus this swap
                        reaches $25,000 → same REVERT, even across different tokens. Native units are not added.

No / stale feed         Token has no governor-set Chainlink feed, or latestRoundData.updatedAt is older than
                        priceStalenessThreshold (default 3600s) → `MagnitudeQuoteFailed`. Fail-closed.

Published score 0       Keeper writes score 0 with a fresh updatedAt. E is now confirmed-clean.
                        A $1m swap of already-held funds ALLOWs. Magnitude REVERT applies only while updatedAt == 0.

Units                   Floors are USD with 8 decimals (Chainlink). Governor binds each pool token via setPriceFeed.
----------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------
```

## 8. Conclusion

This scenario demonstrates the complete decision space of AML Hook in a single execution run. A direct attack by the exploit source triggers an immediate revert. An attempt to route contaminated funds through intermediary wallets is detected and penalized with mathematically decaying fees proportional to hop distance. A third path that swaps before the keeper publishes the decay score on an already-written clean wallet is caught by the balance-inflow heuristic and still receives FEE_OVERRIDE at 8 percent rather than an unconditioned ALLOW. A brand-new wallet with no score pays 3 percent under $1,000, 8 percent from $1,000 to $24,999, and is reverted at or above $25,000 (or if the Chainlink quote fails). Successful decisions emit `SwapObserved`; reverted attempts are distinguished by `SanctionHit`, `WalletBlocked`, `UnscoredMagnitudeBlocked`, `InflowMagnitudeBlocked`, or `MagnitudeQuoteFailed`.

The attack vectors covered — direct exploit cash-out, multi-hop fund propagation, cash-out inside the oracle latency window, and a large first swap from an unknown wallet — represent primary evasion strategies used in DeFi exploits. AML Hook addresses them at the execution layer, without requiring the attacker to appear on any external list, and without introducing latency into the normal swap path for clean addresses with a fresh keeper score.
