# AML HOOK

Modular Compliance Layer for Uniswap v4

Gonzalo Emanuel Heredia

## 1. The Problem

DeFi has a structural problem: it does not know who is operating in its pools or how they behaved before. Any address can swap with any other, without anyone recording what happened or why. There is no sanctions control, regulatory traceability, or behavioral history that distinguishes a legitimate actor from an illicit one.

In Web2, the reputation of a financial actor is built over time, through credit history, transaction patterns, and relationships with known counterparties. That reputation determines the conditions under which it operates. In DeFi, every wallet starts from zero on every swap, with no memory and no accumulated consequences. There is no difference between a wallet with ten years of clean history and one created five minutes ago.

For the retail world this does not matter. For the institutional world it is an absolute blocker. A regulated fund such as BlackRock BUIDL, a market maker such as Wintermute, or a European protocol under MiCA cannot operate in an environment where it cannot demonstrate that its counterparties comply with due diligence obligations. The regulators that oversee them require it. It is not a minor choice, it is a condition of existence.

It is worth clarifying the scale of the argument. From the outside this is often seen as a fight between liquidity and compliance. Those of us who have spent years in compliance know that the real tension is between controlled liquidity and uncontrolled liquidity. This is not about making a system more expensive or blocking transactions, it is about enabling greater inflows of funds.

Institutions are leaving DeFi because they cannot distinguish clean liquidity from that which is not. The result is that there is USD 25 billion in RWAs on-chain that do not circulate in DeFi. The missing layer is the one that enables institutions to participate with regulatory certainty.

### 1.1 Why Existing Solutions Are Insufficient

The problem has already been identified in the market and in recent launches. There are serious projects that have addressed it and do so well within their limits. Verifying identity before a swap is a necessary starting point for knowing the counterparty, but it is not sufficient.

As will be shown throughout this document, existing solutions perform a check at the moment of the swap and issue a verdict: the wallet is authorized or it is not. They check whether an address appears on a sanctions list, or whether the user holds a valid KYC certificate. If everything is in order, the operation executes. That control is real and has value. The problem is that it stops there.

Traditional banking institutions do not operate that way. Their regulators do not ask them to verify identity once and forget about it. They require continuous monitoring, that they observe the behavior of their counterparties over time, that they detect suspicious patterns even when no one appears on any list, and that they act on reasonable suspicion, even before certainty.

A wallet can pass any identity check today and tomorrow execute forty small swaps in six hours to fragment a large amount, configuring a classic AML typology called structuring. No system that only looks at the moment of the swap will detect it. Nor does it detect when a new wallet receives funds from a high-risk wallet hours before operating, or when the transaction pattern is statistically consistent with an exit liquidity scheme.

Hedi Navazan, Chief Compliance Officer at 1inch Labs, put it precisely: "risk assessment should be holistic, considering a variety of factors, not a single indicator such as transaction volume" (link). That critique does not invalidate existing solutions, it describes their limit. And that limit is exactly the space AML Hook occupies.

DeFi needs a system that builds a film, not a photograph. One that accumulates the behavioral history of each wallet, detects emerging patterns, and calibrates its response according to the actual risk level. The same logic a bank applies when it decides between approving an operation, escalating it for review, or rejecting it.

The model is analogous to the verification a credit card network performs at the point of sale. The network does not compute a fraud score from scratch when the card is presented; it queries a risk profile that was already calculated and cached ahead of time, and returns an authorization signed instantly. AML Hook follows the same logic: the off-chain engine keeps every wallet's risk profile continuously updated in the background, and the swap only queries a value that already exists. The blockchain does not perform any heavy computation on-chain, and the swap settles in the same block it would have settled in without the hook.

### 1.2 Why Now

Institutional capital in DeFi is at an early stage. When that capital arrives at scale, what Standard Chartered anticipates with its USD 100 price target for UNI, it will need exactly the infrastructure this project builds. It is being built before demand becomes obvious to everyone.

In July 2026, Uniswap Labs published the official documentation for Permissioned Pools, its own native pool-level access control solution. That publication confirms that compliance on Uniswap v4 has stopped being a market hypothesis and has become a priority recognized by the team that builds the protocol. It also precisely delimits the space AML Hook occupies: the Labs solution addresses access control, not behavioral monitoring.

### 1.3 Point-of-Execution Control and Its Limits

Understanding why AML Hook is structurally different from a banking control requires understanding how banking control actually works. A bank detects a suspicious operation, analyzes it, files a Suspicious Activity Report (SAR), and in some cases freezes the account. All of this happens after the funds have already moved. The bank does not intervene at the moment of the transaction: it records, reports, and eventually acts on accounts, not on individual movements already executed. The control mechanism is documentary and retroactive.

The chain of custody that makes that retroactivity possible is long: the bank knows the client, holds their documentation, can freeze the account, can respond to a judicial request, and can cooperate with FinCEN or OFAC with identity information. The control works because that infrastructure of identity and custody exists behind it.

That infrastructure does not exist on-chain. When the hook executes beforeSwap, the transaction is pending but not confirmed. If the hook does not revert, the transaction is confirmed and the assets move irreversibly within the same block. There is no review period, no account to freeze, no institutional counterparty holding funds while it analyzes. The only possible moment of intervention is before confirmation. Once the block is mined, no on-chain mechanism can undo the movement. A bank can freeze an account tomorrow for a transaction made today. A hook that did not revert has no second chance.

That restriction is simultaneously the limitation and the value of the hook. The limitation is that it cannot do what a bank does after the fact. The value is that it can do what no bank can do: intervene at the exact point of execution, before the funds move, with complete on-chain information about the history of the addresses involved. A bank that detects that its client received funds from an address linked to ransomware learns this days or weeks later, once the funds have already passed through multiple hops. The hook knows it within the same block, with the same information publicly available on-chain, and can act on that specific transaction before it settles.

This produces three concrete applications with no banking equivalent. First, screening at execution time: the match against a Specially Designated Nationals (SDN) address is verified before the swap, not after, so the institutional integrator has evidence that every transaction was evaluated at the moment of execution rather than audited retroactively, which turns the compliance record from a log of what happened into evidence of active control. Second, exposure granularity: a banking system sees its client's wallet address, not the full history of that address or its prior counterparties, while a hook with on-chain data access can evaluate the transaction graph of the originating address, including where its funds come from and how many hops separate it from a designated address, a visibility no bank has in real time at the moment of executing an order. Third, immutable traceability of the control itself: the fact that the hook evaluated the transaction and did not block it is recorded on-chain permanently and non-repudiably, which for an integrator subject to audit constitutes due diligence evidence that no off-chain system can generate with the same level of verifiability, since it does not depend on internal logs or the integrity of a centralized database.

All of this operates within a precise perimeter. The hook evaluates and acts on what it can observe on-chain, at the moment of execution, without custody and without documentary obligations of its own. It does not replace a full compliance program, it does not file SARs, and it does not block assets in the regulatory sense of the term. It is infrastructure that makes exposure observable at the only moment when an on-chain intervention is technically possible, and that generates immutable evidence that the evaluation occurred. The use case is built on the gap identified throughout this document: institutional integrators on Uniswap v4 need evidence of active control at the point of execution, and no infrastructure currently provides it natively.

## 2. The Product

### 2.1 General Description

AML Hook is a modular compliance layer that operates natively as a Uniswap v4 hook. Unlike existing solutions, which verify identity only once at onboarding, AML Hook verifies compliance on every swap, in real time, directly at the pool's execution layer.

The hook intercepts the swap lifecycle at two moments, beforeSwap and afterSwap. It runs static screening and dynamic scoring on both parties, builds a cumulative risk profile, and decides whether the operation executes, is conditioned, or is reverted. The cycle closes with a reporting module that allows auditable reports to be presented to regulators.

### 2.2 Product Objectives

Prevention of terrorist financing and money laundering in DeFi pools. Ensure that no participant under international sanctions (OFAC, FATF, local lists) can operate in a pool configured with AML Hook. Every transaction leaves verifiable on-chain evidence of the screening process, creating an auditable trail that demonstrates the protocol's due diligence in any regulatory investigation.

Reduction of regulatory exposure before the SEC, CFTC and equivalents. DeFi protocols that do not implement compliance mechanisms remain exposed to direct regulatory action. AML Hook allows pool operators to demonstrate that they have active sanctions and behavioral controls, significantly reducing the surface of legal exposure before the SEC, CFTC, FinCEN, MiCA and equivalents.

Enabling institutional funds with strict KYC requirements. Institutional funds are prohibited from interacting with anonymous pools. AML Hook creates the infrastructure necessary for those funds to be LPs on Uniswap v4, ensuring that every counterparty meets due diligence obligations. This applies in particular to protocols issuing RWA (Real World Assets), where the underlying asset carries regulatory transfer restrictions.

Generation of additional revenue through risk-differentiated fees. AML Hook introduces a native monetization model at the execution layer. The pool fee adjusts dynamically based on each party's risk score, turning compliance from a cost into revenue. The pool's LPs capture a risk premium from wallets with a history of exposure to mixers or high-risk clusters, low-score wallets receive preferential terms that incentivize compliance, and pools with AML Hook can justify higher yields to institutional investors.

## 3. Hook Architecture

### 3.1 The Swap Lifecycle

The hook operates at two moments in the lifecycle of every swap on Uniswap v4.

```text
----------------- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Moment            Action

beforeSwap        Verifies the seller. Checks whether the source wallet holds valid authorization. If not, it blocks the operation before it executes.

afterSwap         Verifies the buyer. Confirms that the destination wallet is also authorized. If not, it can revert or route the funds to a temporary custody contract. Updates the wallet's risk profile.
----------------- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

### 3.2 The Four Decision Layers

The independent-layer architecture is the most important feature of the design. If one layer fails, the system continues operating with the remaining ones.

```text
---------- ---------------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Layer      Name                         Function

Layer 1    Static sanctions screening   Is this address on OFAC or another sanctions list? Immediate block if there is a match. Fast, with no external dependency at execution time.

Layer 2    Dynamic behavioral scoring   Off-chain behavioral scoring oracle. Analyzes the transaction graph: frequency, volumes, exposure to mixers, structuring, layering. The score is pre-calculated and cached. The hook reads it at the moment of the swap, with no latency.

Layer 3    Execution decision           Takes the inputs from layers 1 and 2 and produces the final decision: block, apply a differential fee, or allow.

Layer 4    Risk profile update          Executed in afterSwap. Sends the behavior observed in the swap, amount, counterparty and timing, as an event to the off-chain scoring engine, which updates the wallet's cumulative profile. It is the layer that turns the system from static to dynamic.
---------- ---------------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

### 3.3 The Three Decision Outputs

The core innovation of AML Hook is its ternary decision logic, as opposed to the binary allow-or-block system of all existing competitors.

```text
------------------ ------------------------------------ -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Score              Output                               Regulatory basis

0 to 30            Allow (standard fee)                 Wallet with no exposure to sanctioned entities, with no anomalous behavioral patterns. Operates normally.

31 to 70           Differential fee (3x the standard)   Wallet with atypical behavior but no confirmed sanction, such as structuring, indirect-risk counterparties or suspicious timing patterns. There is no legal obligation to block it. The fee acts as an economic disincentive and a monitoring signal, equivalent to banking Enhanced Due Diligence (EDD).

71 to 100 / OFAC   Unconditional block                  Wallet on the OFAC sanctions list, direct exposure to mixing services, darknet markets or designated entities. There is no discretion, the transaction reverts.
------------------ ------------------------------------ -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

The differentiator is Output 2. In the real regulatory world, not all risk justifies a block. A regulator does not expect you to block a wallet with a medium score, it expects you to monitor it, segregate it, or apply friction to it. The differential fee is the on-chain translation of that principle, and it also generates revenue for the LPs.

### Regulatory argument for the ternary split

Sanctioned wallet (score 71 to 100 or OFAC match): unconditional block, no fee, the transaction reverts. There is no ternary exit and no discretion. This segment is identical to what any binary competitor already does.

Suspicious wallet without a confirmed sanction (score 31 to 70): this is where the differential fee operates, and the regulatory foundation is that there is no legal obligation to block this tranche. A wallet with atypical behavior (transaction fragmentation, indirect-risk counterparties) but without a match on sanctions lists is not legally in the same category as a sanctioned one. The obligation it generates is monitoring and reporting, not blocking. It is the same principle banks apply under the FATF risk-based approach (RBA / EBR, enfoque basado en riesgo del GAFI): not every medium-risk operation is rejected; enhanced due diligence is applied instead.

### 3.4 Dynamic vs. Static Behavioral Scoring

All existing competitors are static at the moment of the swap: they check whether a credential or a list says something about the wallet at that instant. AML Hook builds a film, not a photograph.

Every time a wallet executes a swap, afterSwap sends that event to the behavioral scoring engine, which updates the risk profile off-chain incorporating the new transaction: amount, counterparty, timing and relationship to the historical pattern. The next time that wallet attempts to swap, beforeSwap queries a score that already incorporates what it did on the previous swap.

The consequence is direct. A wallet can start with a low score and rise in risk because of its on-chain behavior, without anyone having put it on any list. The system detects emerging patterns such as structuring, layering, dust attacks and co-spending, in addition to already-known entities.

### Threat Taxonomy

The patterns AML Hook is designed to detect fall into three categories, organized by the nature of the threat rather than by its source.

The first category groups threats to the origin of funds and sanctions compliance, combining static lists with graph intelligence about where the money comes from. This includes direct matches against international sanctions lists such as OFAC, FinCEN or the FBI; new or historyless wallets funded from infrastructure associated with known attacks; funds arriving directly from mixing or anonymization protocols such as Tornado Cash or Railgun; and multi-hop propagation, where contamination does not arrive directly but reaches the pool cooled down two, three or four transfers removed from its origin, following the N-hop decay logic detailed in the accompanying use case document.

The second category groups behavioral and market-conduct threats: patterns of protocol abuse or market manipulation occurring inside or around the AMM. Wash trading is the same actor, or a coordinated network of wallets, executing inflated buys and sells against each other to simulate volume or manipulate fees. Rug pulls and exit liquidity schemes occur when a token's developers drain the pool's liquidity at once, or use LPs and users as exit liquidity before abandoning the project. Layering is the systematic fragmentation and chaining of multiple consecutive swaps intended to obscure the route the funds take, and is the behavioral root of what compliance frameworks label structuring when the fragmentation is aimed specifically at evading reporting thresholds.

The third category groups real-time and cybersecurity threats, the class of events where a traditional, static KYC check is structurally blind because of latency. Exploit cash-out is the case where an attacker has just drained an external protocol and rushes to swap the stolen tokens into a non-freezable asset before sanctions lists or exchange freezes catch up, the scenario developed in full in the accompanying use case. Account compromise and identity hijacking is the case where a private key is stolen from an institutional wallet that holds legitimate credentials, and the attacker uses those same legitimate permissions to drain the pool or execute layering, meaning the threat is not the address itself but a sudden, anomalous change in the behavior associated with it.

Static, point-in-time checks can only ever reach the first category, and only its list-based component. Graph-based propagation, market-conduct patterns and real-time threats all require the cumulative, event-driven model described throughout this section: none of them leave a trace that a single credential or allowlist lookup can see.

### 3.5 Detailed Technical Architecture

### Call path and on-chain modules

```text
User → Router → PoolManager
                       │
              beforeSwap │ afterSwap
                       ▼
                   AMLHook
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   SanctionRegistry  ComplianceOracle  RiskPolicy
     (Layer 1)         (Layer 2)         (Layer 3, decision)
                          ▲
                          │ updateScore(wallet, score, hopDistance, origin, signature)
                          │
                    Oracle Keeper (off-chain)
```

AMLHook is the Uniswap v4 hook the PoolManager invokes. SanctionRegistry is Layer 1 (static sanctions). ComplianceOracle is Layer 2 (behavioral score store written by the off-chain Oracle Keeper). RiskPolicy is Layer 3 (ternary decision: ALLOW, FEE_OVERRIDE, or REVERT). The keeper monitors external exploit feeds and ERC-20 peer-to-peer transfers and publishes scores via updateScore before the next swap.

### Contract relationship analysis

```text
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
Contract             Role                    Reads / calls                              Writes / emits                                    Does not
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
AmlHook              Orchestrator at swap    SanctionRegistry, ComplianceOracle,        Pool activity in afterSwap; SwapObserved;         Calculate the behavioral score
                     time (beforeSwap /      RiskPolicy; resolves end-user from         LatencyMitigationApplied; may revert            off-chain; hold the sanctions
                     afterSwap)              hookData                                   (SanctionHit, WalletBlocked, MissingSwapSubject)  list itself
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
SanctionRegistry     Layer 1 — static list   Queried by AmlHook via isSanctioned        Owner / ops via setSanctioned                     Score wallets or decide fees
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
ComplianceOracle     Layer 2 — score store   Queried by AmlHook via getRisk /           Keeper via updateScore (score, hopDistance,       Decide ALLOW / FEE_OVERRIDE /
                                             getScore                                   origin, feeBps, updatedAt)                        REVERT
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
RiskPolicy           Layer 3 — ternary map   Called by AmlHook with score +             None (pure / view decision)                       Store scores or sanctions;
                                             recommendedFeeBps → ALLOW /                                                                  talk to Uniswap
                                             FEE_OVERRIDE / REVERT + feeBps
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
Oracle Keeper        Off-chain publisher     Off-chain graph, exploit feeds,            updateScore on ComplianceOracle                   Execute inside beforeSwap
(not a contract)                             SwapObserved trail
-------------------- ----------------------- ------------------------------------------ -------------------------------------------------- --------------------------------
```

Read path at beforeSwap: PoolManager → AmlHook → SanctionRegistry (fail closed on match) → ComplianceOracle (WalletRisk) → RiskPolicy.decide → optional §3.8 elevation of ALLOW to FEE_OVERRIDE using hook-local pool activity. Write path at afterSwap: AmlHook updates per-wallet activity counters and emits SwapObserved for the off-chain engine. Write path between swaps: the keeper alone publishes fresh scores into ComplianceOracle; the hook never writes the oracle.

### Off-chain analysis engine

Continuously processes the on-chain transaction graph. For each wallet it calculates its direct exposure, that is, whether it interacted with blacklisted wallets, and its indirect exposure, whether it interacted with wallets that in turn interacted with blacklisted wallets, at a configurable depth of two to three hops. It also measures the frequency and volume of interactions with risk clusters, and detects related wallets when a new address shares behavioral patterns with one already blocked.

### On-chain oracle

A contract that stores the state of each wallet and that the hook can query: the direct blacklist (OFAC, FATF lists, local lists), the risk score calculated by the off-chain engine, the timestamp of the last update, and the validity of the KYC token issued by an external provider, such as Civic or Polygon ID with ZK-proof.

### Multi-layer architecture with fallback

Instead of depending on a single oracle, AML Hook is designed with redundant layers. The static layer is the updatable on-chain OFAC list, with no external dependency at execution time. The primary dynamic layer is the negotiated provider's oracle, Chainalysis or TRM Labs. And the fallback layer engages when the primary oracle does not respond: the hook executes with the static layer alone instead of reverting the transaction, which eliminates single-point-of-failure risk.

### Verification of institutional Smart Accounts

A critical case that competitors ignore is that institutional funds do not use simple wallets. They use Smart Accounts, multisigs such as Safe that require several executives to sign each transaction. When the swap reaches the hook in beforeSwap, msg.sender is a contract and not a person, it has no directly associated KYC and does not appear on sanctions lists.

The same structural ambiguity appears with the Uniswap router. In a normal swap path the PoolManager's beforeSwap caller is typically the router contract, not the end user. Scoring or sanctioning that router address would be meaningless: either every swap would inherit a clean router score and bypass control, or a contaminated router score would block the entire pool. AML Hook therefore never treats the router as the compliance subject. The end-user wallet must be supplied explicitly in hookData as abi.encode(user). If hookData is missing, empty, or decodes to the zero address, beforeSwap reverts with a dedicated fail-closed error (MissingSwapSubject) before Layer 1, Layer 2, or Layer 3 run. There is no fallback to msg.sender. Integration responsibility sits with the router or front-end path that builds the swap: without a declared subject, the operation does not execute.

AML Hook resolves institutional Smart Accounts with two verification models. In controller verification, the hook checks who the owners of the Smart Account are and verifies each one individually, so that if any controller is sanctioned, the swap is blocked. In threshold verification, it is not enough for one controller to be clean, it verifies that there are enough clean controllers to meet the multisig's approval threshold. If the threshold is three of five and a sanctioned controller is not enough to approve anything on its own, the swap can proceed. In both models the address under evaluation remains the subject declared in hookData, not the router that forwarded the call.

### 3.6 Regulatory Reporting Module

In afterSwap, the hook emits structured events with sender, amount, timestamp and verification result. These events are recorded on-chain in the order they occur, interleaved with every other contract's events, block after block, with no organization by wallet or by date on their own.

The Graph is the indexing layer that solves that problem. Indexing means reading the full history of a contract's events, ordering it and keeping it updated in a queryable structure. A subgraph is deployed once, declaring the hook's address and which events to track; from that point on, The Graph reads the chain and keeps the data current on its own, queryable through GraphQL. The reporting module described in this section, and the Compliance Officer Agent described in section 8, both consume the hook's event history through this layer rather than by walking the chain block by block: The Graph is the data source that both tools query, not a component of the hook's own logic.

For the UHI10 prototype, this indexing layer is not required to demonstrate the hook's core behavior. The ternary decision outputs and the on-chain state the hook itself maintains are readable directly from contract storage, with no indexing layer involved. The Graph becomes necessary once the objective is to display the indexed history, such as a panel listing all events for a given wallet over time, or to feed the analysis agent described in section 8. For the prototype, this can be simulated: Anvil, Foundry's local node, exposes the logs emitted in afterSwap, and a script can read those logs after each block and persist them in memory or in a JSON file, which a dashboard or agent can then query in place of a subgraph endpoint. The visible result is identical; the difference is limited to the underlying infrastructure, which in production is The Graph and in the demo is a small local script. What cannot be simulated is decentralization and mainnet availability, but that is not what the hackathon evaluates.

This allows pool operators to generate auditable reports to present to regulators such as the SEC, the CFTC, FinCEN or MiCA, demonstrating the due diligence process transaction by transaction. The audit log is immutable: every system decision is recorded with timestamp, risk score, sources consulted and action taken. The interpretive analysis of those events, with typology identification and natural-language documentation, is developed in section 8.

### 3.7 Fee Escrow Mechanism

For medium-risk swaps, with a score between 31 and 70, the differential fee does not go directly to the pool. It goes to an escrow contract with a 48-hour timelock. During that period, if the oracle confirms that the wallet was part of a fraud scheme, because it appeared on a Chainalysis list, because related wallets were flagged, or because the pattern completed, the fee is not released to the pool but instead goes to a compensation fund for the affected LPs.

If there is no fraud confirmation within 48 hours, the fee is released normally. The mechanism has two concrete effects: it creates a real economic cost for the attacker even if it manages to pass the initial filter, and it funds the compensation of the LPs. It turns compliance from a passive cost into an active pool-protection asset.

### 3.8 Oracle Latency and Update Frequency

The behavioral calculation does not happen during the swap. The off-chain engine calculates the scores continuously and a keeper writes them on-chain periodically. When a swap arrives, the hook reads a value that was already stored. The operation concludes within the network's normal confirmation time, around 12 seconds on Ethereum mainnet and close to 1 second on Unichain and most L2s (Layer 2, second-layer networks). Compliance adds no perceptible wait.

The freshness of the behavioral score depends on the keeper interval, and that interval is not uniform across signal types: each type of signal tolerates a different latency and carries a different write cost. An OFAC match is event-driven and deterministic, written as soon as the list is updated rather than on a fixed interval, since the volume involved is a few dozen addresses per update and the tolerable latency is low because the obligation is objective. Behavioral score updates, by contrast, run on an interval: 30 to 60 seconds for high-volume institutional pools and 3 to 5 minutes for retail pools. That figure is the maximum age of the data, not a delay in the operation.

There is a structural gap that must be mitigated on-chain, not only described: if an address executes a swap and that swap changes its risk profile, the score the hook reads on the following swap may not yet reflect it, so an actor operating across consecutive blocks can transact against a stale or missing score. AML Hook implements three concrete mitigations in beforeSwap / afterSwap (AmlHookLogic), configurable at deploy time via maxScoreAge, activityWindow and maxOpsInWindow.

Mitigation A — never written. ComplianceOracle stores updatedAt with every keeper write. If updatedAt is zero, the wallet has never received a keeper publication. RiskPolicy alone would map score 0 to ALLOW; the hook overrides that path and elevates to FEE_OVERRIDE (default latency fee 8%, or the keeper-written feeBps when present). A legitimately clean wallet must therefore be published explicitly with score 0 and a non-zero updatedAt. This is the on-chain distinction any auditor expects between "unknown" and "confirmed clean."

Mitigation B — stale score with pool activity. If block.timestamp minus updatedAt exceeds maxScoreAge, and the hook's own lastSwapAt for that wallet is strictly greater than updatedAt (the address has swapped in this pool since the last oracle write), ALLOW is elevated to FEE_OVERRIDE. A stale score with no subsequent pool activity does not by itself elevate: inactivity does not prove contamination, but activity against an expired score does justify the intermediate tier until the keeper refreshes.

Mitigation C — hook-local activity window. Independently of the oracle, afterSwap records per-wallet pool activity (window start, operation count, lastSwapAt) in a rolling activityWindow. When the operation count in the current window reaches maxOpsInWindow, the next beforeSwap elevates ALLOW to FEE_OVERRIDE. This counters burst behavior across consecutive blocks while the keeper has not yet moved the score tier. The counter resets when the window elapses.

These mitigations only elevate ALLOW to FEE_OVERRIDE. They never soften REVERT or a policy FEE_OVERRIDE already returned from RiskPolicy. Each elevation emits LatencyMitigationApplied with a reason code (SCORE_NEVER_WRITTEN, STALE_WITH_POOL_ACTIVITY, or ACTIVITY_WINDOW_CAP) for the audit trail. Default deploy parameters used in the local stack are maxScoreAge = 5 minutes, activityWindow = 1 hour, maxOpsInWindow = 3; operators may override them at deploy time.

The keeper writes only when the score variation exceeds a configurable threshold that changes the hook's decision tier, not on every recalculation. An address moving from 12 to 15 does not trigger a write; one moving from 28 to 34 does, because it crosses into the differential-fee tier. This reduces writes to a small fraction of recalculations. Independently of the interval chosen, the score carries the timestamp of its last update in the same WalletRisk storage record, which is what enables Mitigations A and B.

### 3.9 Complete Walkthrough of a Swap

This section describes the complete lifecycle of an exchange operation in a pool configured with AML Hook, from the user's signature to block confirmation, specifying at which moments the hook intervenes and what it executes at each one. It is written without assuming prior knowledge of Uniswap v4's architecture.

Version 4 of the protocol concentrates all pools in a single contract called the PoolManager. That concentration is the architectural condition that makes hooks possible, since there is a single execution point where external logic can be inserted. The PoolManager also operates under a deferred accounting scheme, in which each party's obligations are recorded during the operation and settled at close.

Step 1. Signing and submission of the transaction. The user selects the pool, the amount and the direction of the exchange, and signs the transaction with their wallet. The transaction is directed to a router contract that acts as an intermediary. The user does not interact directly with the PoolManager. No compliance control intervenes at this stage.

Step 2. Acquiring the PoolManager lock. The router invokes the PoolManager's unlock function. The contract is marked as unlocked and returns control to the router through a callback called unlockCallback. This mechanism exists so that the PoolManager can verify, at the end of the sequence, that all recorded obligations have been settled.

Step 3. Invocation of the swap function. Within the lock, the router calls the PoolManager's swap function and passes it the PoolKey, which identifies the pool through the two currencies of the pair, the fee, the tick spacing and the address of the associated hook, together with the operation's parameters and a field called hookData. In the Uniswap v4 interface hookData is optional; for AML Hook it is required: it must carry abi.encode(endUser), the wallet that is the actual compliance subject. Two further parameters are decisive for AML Hook. The zeroForOne field indicates the direction of the exchange, that is, which of the two currencies is delivered and which is received, which enables the analysis of directional turnover patterns. The amountSpecified field indicates the amount of the operation, and is a direct input for the risk scoring model.

Step 4. Hook identification and permission verification. The PoolManager obtains the hook's address from the PoolKey. A pool with no hook has that field set to zero and the sequence continues directly at step 6. Uniswap v4 encodes the hook's permissions in the least significant bits of its own contract address, so that the address determines which lifecycle functions it has enabled and avoids additional lookups at execution time. The practical consequence is that deploying a hook requires locating an address that contains the corresponding bit pattern. AML Hook requires the beforeSwap, afterSwap and dynamic fee modification permissions.

Step 5. Execution of beforeSwap, AML Hook's first intervention. The PoolManager invokes the hook's beforeSwap function before executing any movement of funds. Before any compliance layer runs, the hook resolves the swap subject from hookData. If hookData does not contain a non-zero end-user address, the function reverts immediately (MissingSwapSubject). The hook never falls back to the router as msg.sender, because a router cannot be scored or sanctioned as if it were the economic actor. Once a valid subject is present, the hook queries Layer 1: the on-chain registry of sanctioned addresses for that wallet. On a confirmed match, the function reverts immediately and the transaction is cancelled in full, with no subsequent evaluation or margin of discretion. In the absence of a match, the hook reads the behavioral score and the keeper-written recommended fee stored in the oracle, calculated off-chain beforehand according to the scheme in section 3.8, and applies RiskPolicy's ternary mapping. If the policy result would be ALLOW, the hook then applies the section 3.8 latency mitigations: never-written score, stale score with subsequent pool activity, or activity-window cap — any of which elevates the outcome to FEE_OVERRIDE and emits LatencyMitigationApplied. Low risk with a fresh keeper write and no activity-cap hit: the operation continues at the standard fee. Intermediate risk: it returns an increased fee that the PoolManager applies to this operation, preferring the fee the keeper published with the score. High risk: it reverts the transaction, with the basis recorded.

Step 6. Execution of the exchange and calculation of the BalanceDelta. The PoolManager executes the pool's arithmetic: tick traversal, determination of the execution price and calculation of the output amount. The result is expressed in a structure called BalanceDelta, which records each party's pending obligation with respect to each of the two currencies. At this stage no token has been transferred. Deferred accounting records balances in transient memory and defers settlement to the close of the sequence.

Step 7. Execution of afterSwap, AML Hook's second intervention. Once the operation has executed, the PoolManager invokes the afterSwap function and passes it the result. This is the moment at which AML Hook writes state, which constitutes its structural difference from existing solutions. The hook updates its per-wallet pool activity record used by section 3.8 (window start, operation count, lastSwapAt), which is available immediately and does not depend on the oracle. It then emits SwapObserved with the address, the score, the decision adopted, the fee and hop metadata, and the off-chain scoring engine consumes that trail so it can update the wallet's cumulative risk profile ahead of its next swap. That emitted event constitutes the input for the reporting module in section 3.6 and, in the later development track, for the analysis agent in section 8.

Step 8. Settlement of pending balances. Control returns to the router, which must cancel the recorded obligations, transfer the currency delivered by the user and withdraw the currency acquired. The protocol provides for an alternative, consisting of keeping the credit balance within the PoolManager as a withdrawal right, without extracting the tokens.

Step 9. Verification of zero balances and release of the lock. Once the router's actions are complete, the PoolManager verifies that all recorded obligations have reached zero. On any pending balance, it reverts the entire transaction. Once closure is verified, it releases the lock.

Step 10. Block inclusion and confirmation. The transaction is incorporated into a block and reaches confirmation, in approximately twelve seconds on Ethereum mainnet and around one second on Unichain and most L2s.

Of the ten steps described, AML Hook intervenes in two: step 5, before any movement of funds, and step 7, once the operation has executed. The rest of the sequence is identical to that of any Uniswap v4 pool. The structural difference relative to all existing solutions is concentrated in step 7, the only moment in the cycle at which the system records memory of the observed behavior and hands it off to the off-chain scoring engine.

## 4. Legal and Regulatory Framework

### 4.1 Applicable Frameworks

```text
---------------------------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Framework                                Application in AML Hook

OFAC/SDN Screening                       Query of the Office of Foreign Assets Control list directly in Layer 1. Unconditional block on any match, with no discretion.

FATF Recommendation 15 (VA)              The product operates under the FATF Rec. 15 standard (2018 revision) and the FATF Guidance on Virtual Assets 2021/2023. If the operating entity has any point of control over the protocol, it can be classified as a VASP, activating the full set of AML/CFT obligations.

MiCA (Europe)                            Requires virtual asset service providers to implement KYC and sanctions screening. A European DEX without the hook must run screening off-chain and block at the interface, which is easily bypassed. With the hook, the control is native to the protocol.

SEC/CFTC Regulation (U.S.)               Compliance with broker-dealer obligations for operations involving assets that may be classified as securities. The reporting module generates the audit trail that allows controls to be demonstrated in an investigation.

GENIUS Act (2025)                        Legal framework enacted in the United States for fully reserved payment stablecoins. AML Hook is compatible with the Circle and USDC standards required by this framework.

Transaction Monitoring (FATF / FinCEN)   Regulators do not require preventing 100% of fraud, they require a reasonable system of monitoring and documentation of actions taken. AML Hook implements transaction monitoring in real time at the protocol level, without needing wallet KYC, using behavior as a risk proxy. It is a genuinely new regulatory proposal for DeFi.
---------------------------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

The prototype developed in UHI10 is built in conformity with FATF standards as an international reference baseline. The hook's modular architecture allows coverage to be extended to the specific jurisdictions in the table, MiCA, SEC/CFTC and the GENIUS Act, without modifying the contract's core logic. Each pool operator configures the regulatory layers that correspond to its jurisdiction.

### 4.2 Operational Compliance Obligations

The product must meet the following standards to be regulatorily viable.

Source-of-funds screening (Rec. 3 / Rec. 10). Screening against OFAC/SDN lists combined with blockchain forensics from Chainalysis, TRM Labs or an equivalent, with N-hop backward tracing to detect self-laundering and mixed funds. The system cannot be binary, it must produce a risk score with documentary traceability.

Ongoing CDD and monitoring (Rec. 10). Updating wallets' risk profiles over time, not only at onboarding, with an Enhanced Due Diligence threshold for high-risk transactions defined in internal policy.

Record retention (Rec. 11). Immutable audit log of every decision, with timestamp, risk score, sources consulted and action taken, and a minimum retention of five years.

Suspicious transaction reporting (Rec. 20). Automatic or manual trigger of an STR (Suspicious Transaction Report) when the risk score exceeds the defined threshold. The activation standard is reasonable suspicion, not certainty. Waiting for certainty is non-compliance.

The perimeter of the product must remain explicit alongside these obligations. AML Hook does not file SARs or STRs on its own behalf, does not constitute blocking in the regulatory sense of the term, and does not qualify as a money transmitter. What it produces is the evidentiary basis, the on-chain screening record and the behavioral audit trail, that the operator's own compliance function uses to meet Recommendations 3, 10, 11 and 20. Stating plainly what the product does not do is, for an institutional integrator evaluating it, more valuable than a broad claim of capability left undefined.

## 5. Competitive Differentiation

### 5.1 Full Competitive Map

The compliance-hooks space on Uniswap v4 has seven identifiable players, grouped into two categories.

### Group 1: Static identity verification (binary KYC)

Civic Hook verifies KYC of identity documents by issuing a non-transferable NFT, the Civic Pass, with binary logic of holding or not holding the Pass. Violet Hooks uses the VioletID registry for identity checks, also binary. Coinbase Verified Pools is limited to those already verified on Coinbase, pure static KYC. Uniswap Labs' Permissioned Pools, documented in July 2026, maintains an on-chain allowlist controlled by the asset issuer, verified on every swap and every liquidity contribution, with binary authorized-or-not logic.

### Group 2: Institutional compliance (AML/CFT with off-chain data)

PureFi Verifier Hook uses ZK-proofs with tiered verification based on swap volume, with a single centralized issuer (AMLBot) and a score valid for 15 minutes, a point-in-time photograph with no cumulative profile. Predicate, with USDL and Paxos, received a USD 325,000 grant from the Uniswap Foundation and produces off-chain cryptographic attestations evaluated by a network of operators, in production on Ethereum Mainnet for wUSDL/USDC, with binary verification and no behavioral scoring. Levery applies bank-grade KYC/KYB checks at beforeSwap for institutional venues: binary pass-or-fail against an off-chain identity pipeline, with no cumulative behavioral score, no afterSwap trail and no dynamic fee.

```text
-------------------- ------------------------ ----------------------- ------------- ----------- --------------- ---------------------------
Competitor           Active hook              Scoring type            Dynamic fee   afterSwap   Open protocol   Status

PureFi               beforeSwap               Threshold by amount     No            No          Partial         Mainnet (UFI/BNB)

Predicate/USDL       beforeSwap               Static attestation      No            No          No              Mainnet (wUSDL/USDC)

Coinbase Verified    beforeSwap               Static KYC              No            No          No              Mainnet

Civic Hook           beforeSwap               Identity                No            No          Yes             Deployable

Violet Hooks         beforeSwap               Identity                No            No          Yes             Deployable

Levery               beforeSwap               Bank KYC/KYB            No            No          No              Institutional

Permissioned Pools   beforeSwap               Issuer allowlist        Yes           No          No              Documented (Uniswap Labs)

AML Hook             beforeSwap + afterSwap   Historical behavioral   Yes           Yes         Yes             In development (UHI10)
-------------------- ------------------------ ----------------------- ------------- ----------- --------------- ---------------------------
```

### 5.2 Permissioned Pools, Uniswap Labs' Native Solution

In July 2026, during the development of this project within UHI10, Uniswap Labs published the official documentation for Permissioned Pools. It is the first restricted-access solution documented by the protocol's own team, and for that reason it becomes the ecosystem's reference point.

### How it works

The asset issuer maintains an on-chain allowlist of authorized addresses. Before each swap and each liquidity contribution, the hook queries that list and allows or reverts the operation. For a token with transfer restrictions to be compatible with Uniswap v4's standard PoolManager, the system introduces a wrapper contract called the Permissions Adapter: the restricted token is wrapped upon entering the pool and unwrapped upon leaving it, so that the holder always ends up with the original asset. The issuer retains the ability to pause swaps and liquidate positions, and the liquidity position NFTs are non-transferable to prevent bypassing the allowlist.

What it solves

It solves the problem of the issuer that needs to restrict who can have exposure to its asset. It is the Uniswap v4 translation of the model that Securitize already applied at the token level, and it correctly covers the cases of tokenized assets and regulated assets with transfer restrictions.

What it does not solve

The verification is binary, static and determined outside the protocol. The hook does not calculate a score, does not observe behavior, does not accumulate a per-wallet profile and does not calibrate its response. A wallet added to the allowlist after a valid KYC process can execute systematic layering or accelerated fund rotation within the pool without the system recording it, because the only question it asks is whether the address appears on the list. The continuous monitoring required by FATF Recommendation 10 falls outside its scope by design.

Strategic implication

Permissioned Pools defines the floor on which AML Hook builds. It is access control, and AML Hook is behavioral monitoring. A pool can adopt both, and the combination is more solid than either of the two separately. Its official publication also provides an external validation argument, since the team that builds Uniswap v4 recognizes that pool-level compliance is a real need of the ecosystem.

## 6. Target Market and Customers

### 6.1 Market Size

The market argument is built in three layers.

```text
------- -------------------------- ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Layer   Name                       Size

TAM     Total addressable market   The tokenized RWA market reaches USD 100 billion by the end of 2026, with BCG and Ripple projections that take it to USD 18.9 trillion by 2033.

SAM     Serviceable market         The mid-market private credit and non-institutional RWA segment that needs compliance but does not have access to enterprise solutions. Today it is around USD 5 billion in active on-chain private credit outside the large players. By 2027, potentially USD 15 billion.

SOM     Initial market             The pools of Centrifuge, Goldfinch, Clearpool and equivalent protocols that already have active liquidity and need to differentiate on compliance in order to grow. They are dozens of concrete, identifiable pools, with measurable TVL.
------- -------------------------- ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

### 6.2 The Strategic Segment: Mid-Market Private Credit

On-chain private credit reached USD 3.2 billion in March 2026 (link), up 180% year over year. This segment is the right target for three specific reasons.

No access to enterprise solutions. They have no access to Predicate. Issuers such as Maple, Centrifuge and Goldfinch structure senior secured loans, SME financing and receivables in tokenized formats. None has a relationship with Predicate or Paxos's compliance budget.

Consolidation creates the gap. Sector consolidation is a signal of opportunity. Centrifuge saw its market share fall from 20.6% to 3.3%, and Goldfinch from 17.6% to 2.5%. The protocols losing ground do so in part because they cannot offer the compliance guarantees that Maple's institutional pools do offer.

Yields justify the cost of compliance. Private credit yields in 2026 are between 8% and 12%, well above the 4% to 5% available on Treasuries. A pool that can demonstrate credible AML controls justifies that yield differential to institutional investors who would not otherwise enter.

### 6.3 Additional Segments

DeFi protocols that want institutional access. Institutional funds such as BlackRock, Fidelity and Franklin Templeton cannot interact with anonymous pools. Their regulatory obligations prevent them from depositing into a contract where the counterparty may be a sanctioned or unverified address. If a DeFi protocol wants those funds to be LPs, it needs to offer them a pool with embedded compliance.

Protocols that issue RWA. If a protocol tokenizes treasury bonds, real estate or commercial invoices, the underlying asset carries regulatory transfer obligations. The hook imposes those restrictions directly in the liquidity pool. The Securitize-BlackRock-Uniswap case (BUIDL) is exactly this model. Securitize implements those restrictions in the token itself, within the transfer function of the ERC-20 (Ethereum Request for Comments 20) standard, which creates incompatibility with Uniswap v4's PoolManager, which moves balances internally through ERC-6909 without invoking transfer. Permissioned Pools resolves that incompatibility by moving the token verification to the pool through a wrapper contract. The underlying compliance model is identical in both cases, an allowlist managed by the issuer. AML Hook operates on the next layer, which neither of the two covers.

Decentralized exchanges under VASP license. MiCA in Europe requires virtual asset service providers to implement KYC and sanctions screening. A DEX operating under a MiCA license needs its pools to have those verifications. Without the hook, the DEX would have to run screening off-chain and block at the interface level, which is easily bypassed by interacting directly with the contract.

Institutional market makers with their own AML obligations. Jump Crypto, Wintermute and Cumberland are regulated entities that provide liquidity in DeFi but have their own AML obligations. If the pool in which they operate has no control, their regulatory exposure is real and they cannot participate.

### 6.4 Concrete Potential Customers

```text
------------------------------- ------------------------------- ------------------------------------------------------------------------------------------------------
Entity                          Category                        Problem AML Hook solves

Centrifuge                      Mid-market private credit       Needs compliance to compete with Maple and access institutional capital without Paxos's budget

Goldfinch                       Mid-market private credit       Market share loss correlated with the absence of institutional compliance guarantees

Clearpool                       Mid-market private credit       Uncollateralized liquidity pools that need counterparty controls

Ondo Finance                    Institutional RWA               Tokenizes Treasury bonds and operates with manual allowlists due to the absence of native compliance

European operators under MiCA   Regulated DEXs                  Need to demonstrate AML compliance to regulators and today have no native response on Uniswap v4

Coinbase / Kraken               Exchanges with DeFi ambitions   Licenses that require them to maintain AML standards even in decentralized operations
------------------------------- ------------------------------- ------------------------------------------------------------------------------------------------------
```

## 7. Tooling and Provider Ecosystem

### 7.1 Data Sources and Risk Signals

AML Hook's oracle does not depend on a single source. The optimal architecture is a weighted-signal aggregator, where each source contributes to the final score with a different weight according to its reliability.

```text
------------------------------ ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- ---------------
Source                         Description                                                                                                                                                                                                                                           Type

OFAC SDN List                  U.S. Treasury list. Since 2018 it explicitly includes crypto addresses. Tornado Cash was sanctioned in August 2022, the first smart contract sanctioned and not just a person. Public, updated in real time, indexed on-chain by multiple projects.   Official

Chainalysis Oracle             Institutional standard. On-chain mapping of sanctioned addresses queryable directly in beforeSwap. Fast. Its limitation is the binary output, sanctioned or not.                                                                                      Commercial

TRM Labs / Elliptic            Coverage comparable to Chainalysis. TRM is strong in Latin America and with governments, Elliptic dominant in Europe. Integration mainly off-chain.                                                                                                   Commercial

Forta Network                  Distributed detection bot network. Real-time alerts on exploits, rug pulls and anomalous behavior, sometimes with minutes of anticipation. Public alerts queryable via API.                                                                           Decentralized

Ethereum Attestation Service   Protocol for on-chain attestations about any entity. Organizations publish wallet risk attestations. Basis for a decentralized reputation system.                                                                                                     Decentralized

Hypernative                    Real-time on-chain alerts. Detects exploits and anomalous behavior in advance. Signal source for the AML Hook oracle.                                                                                                                                 Commercial

DeFiLlama Hacks DB             Public registry of all known DeFi hacks with the wallets involved. Well maintained and open source.                                                                                                                                                   Community

FinCEN / FATF advisories       Define the typologies that compliance systems must detect. They are not address lists but behavioral patterns. They design the behavioral scoring.                                                                                                    Regulatory
------------------------------ ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- ---------------
```

What differentiates AML Hook is not having access to these sources, which Civic Hook and PureFi also use. The difference is that it combines them with its own behavioral scoring and produces a graduated output instead of a binary one.

### 7.2 On-chain Screening Oracles (Layer 1)

```text
------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Provider            Description

Chainalysis         De facto standard for large regulated exchanges. Maintains an updated on-chain mapping of sanctioned addresses. KYT (Know Your Transaction) and Reactor for investigation. Leading institutional coverage.

TRM Labs            Risk API with comparable coverage. Rapid expansion in on-chain integrations. More granular risk coverage for exchanges and mixers.

Elliptic            Strong in Europe, also used by banks with crypto exposure. On-chain infrastructure less mature than Chainalysis.

Solidus Labs        Specifically oriented to DeFi and exchanges. Market manipulation detection in addition to AML.

0xAML and similar   Open-access on-chain registries of sanctioned addresses. Alternative layer with no dependence on a centralized provider.
------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

### 7.3 On-chain KYC Solutions (Identity with ZK)

```text
------------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Provider                  Description

Polygon ID                Identity with zero-knowledge proof (ZKP): allows demonstrating that a wallet complies with KYC without exposing the underlying personal data. The approach most aligned with regulatorily defensible privacy.

Civic                     KYC with on-chain credential. Verification of identity documents, location and humanity. Issues a non-transferable NFT, the Civic Pass.

Worldcoin                 Biometric proof of humanity. Use case oriented to Sybil resistance rather than regulatory KYC.

Notebook Labs / Holonym   ZK identity: the user proves attributes, such as not being a citizen of a sanctioned country or not being on the OFAC list, without revealing their identity.
------------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

### 7.4 Off-chain Oracle Infrastructure

For the behavioral scoring oracle there are two paths. Chainlink Functions and CCIP is the production option, with a node that executes the scoring function off-chain and writes the result on-chain with a verifiable cryptographic signature. The proprietary signed system, recommended for the UHI10 prototype, calculates the score on a server, signs it with a known private key and the hook verifies that signature on-chain.

The Graph belongs on the reporting side of this infrastructure, not on the scoring side. Its function is not to calculate risk but to make the events the hook already emitted queryable over time, feeding the reporting module and the compliance agent described elsewhere in this document. For the prototype, that indexing layer is the component most easily replaced by a local mock without affecting the credibility of the demo, since the jury evaluates the hook's decision logic and its live counters, not the indexing infrastructure behind the reporting layer.

### 7.5 Community Reporting Network

No competitor is building this yet: a native Uniswap v4 reporting network. A pool's own LPs can report suspicious on-chain behavior. Those reports, when they accumulate from multiple independent sources about the same wallet, automatically raise its score.

The design resolves three decisions to prevent the mechanism from being manipulated. As to who can report, only the pool's LPs with a minimum stake deposited, who have skin in the game because if the pool suffers a rug pull they lose, and the stake creates an economic cost for malicious reports. As to how it is validated, a single report does not change the score, a threshold of independent reports within a time window is required plus a challenge period during which the reported wallet can dispute, and old reports weigh less through temporal decay. And as to its effect, the report raises the score enough to move the wallet into the differential-fee tier, not to a direct block, which only occurs with multiple validated reports plus the signals of the behavioral oracle.

The network effect this builds is AML Hook's real defensive moat. Every pool that adopts the hook contributes reports to a registry shared among all the pools. A wallet reported in the ETH/USDC pool also has an elevated score in the WBTC/USDC pool. Over time, the registry accumulates an intelligence that no competitor can replicate quickly, because it requires real adoption of the protocol. The more pools, the better the detection. The more LPs, the more signals. It is a flywheel.

## 8. Compliance Officer Agent (COA)

A second development track identified and excluded from the scope of UHI10. It covers the interpretive analysis and regulatory documentation layer that the hook's logic does not produce.

The score is a number, and a number does not explain why an address is risky, does not identify which behavioral pattern triggered the alert, and does not produce documentation that the pool operator can present to a regulator. That gap is regulatorily relevant. When a supervisor audits an operator, it does not only ask how many transactions it blocked, it asks why it blocked them and requires evidence of due diligence, which takes the form of a suspicious transaction report with documented reasoning. A system that blocks without documenting satisfies the technical control but not the reporting obligation, and the operator remains exposed even though its system worked correctly. None of the existing market solutions produce documentation.

The COA replicates the process of a human compliance officer over each relevant transaction that passes through AML Hook. It observes the operation, gathers context on the address and the source of the funds, applies AML/CFT typologies documented by FATF and FinCEN, formulates the legitimate hypothesis that could explain the behavior and evaluates whether the evidence refutes it, concludes with a confidence level, and documents all the reasoning.

```text
----------- ------------------------------------------------------------- ------------------------------------
Category    Criterion                                                     Agent action

Green       Low score, address with clean history                         Minimal logging, no analysis

Yellow      Intermediate score, or patterns inconsistent with the score   In-depth analysis and context memo

Red         High score, or block due to an OFAC match                     Full analysis and STR draft
----------- ------------------------------------------------------------- ------------------------------------
```

The yellow zone is the most relevant. These are the transactions the hook did not block but that warrant review, because they may indicate sophisticated evasion that the score did not fully capture. The analysis memo is the agent's main output, the digital equivalent of the report that a compliance analyst drafts after reviewing an alert. It has an internal use, as a documented audit trail for deciding on gray-zone transactions, and a regulatory use, as the basis for preparing an STR before the competent authority. Its structure is standardized into eight sections: identification of the address, transaction analyzed, history, source of funds with hop tracing, identified typology, alternative legitimate hypothesis, conclusion with confidence level, and actionable recommendation.
