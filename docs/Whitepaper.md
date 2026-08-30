# AML Hook

Modular Compliance Layer for Uniswap v4

Gonzalo Emanuel Heredia

## Executive summary

Institutions stay out of DeFi (decentralized finance) when they cannot tell clean liquidity from tainted liquidity. About USD 25 billion in RWAs (Real World Assets) already sit on-chain without circulating, and the tokenized RWA market is projected at roughly USD 100 billion by end-2026, with BCG and Ripple estimating USD 18.9 trillion by 2033. The missing layer is the one that lets institutional capital participate with regulatory certainty. AML Hook is that layer.

AML Hook is a modular Anti-Money Laundering (AML) compliance layer that runs as a Uniswap v4 hook on every swap in a pool. Binary controls on the market today check static KYC (Know Your Customer) or a sanctions list once, at the moment of the trade. AML Hook keeps a running behavioral history per wallet, updates it swap by swap, and returns one of three outcomes: allow the swap, allow it with an extra fee held for review, or revert it. Permissioned Pools, Uniswap Labs' native access-control product, governs who may enter a pool. AML Hook evaluates how those addresses behave once they hold that access. The two products stack.

No competitor covers both functions. PureFi, Predicate/USDL, Coinbase Verified Pools, Civic, Violet, Levery, and Permissioned Pools itself each check identity or a threshold once, before the swap, with no memory of what the wallet does next. AML Hook runs before and after the swap, keeps historical memory, calibrates a dynamic fee to the actual risk, and leaves an auditable on-chain record: the evidence a regulated fund, a market maker, or a MiCA-regulated (Markets in Crypto-Assets Regulation) operator needs to defend its counterparties to a regulator.

The medium-risk band is also where the product creates a new revenue line: the extra fee the hook prices on an atypical-but-not-confirmed-illicit swap is residual risk the pool would otherwise absorb for free.

This document has three parts. Sections 1 to 7 cover the problem, the product, how it works at a product level, the legal framework, the competitive landscape, the market, and the Compliance Officer Agent. Section 8 is a technical appendix: contract architecture, roles, numeric thresholds, and a step-by-step swap walkthrough, for integrators and technical reviewers.

## 1. The Problem

DeFi leaves unknown both who operates in its pools and how those addresses behaved before. Any address can swap with any other, and nobody records what happened or why. Pools lack sanctions control, a regulatory trail, and a history that separates a legitimate actor from an illicit one.

In traditional finance, reputation builds over time: credit history, transaction patterns, known counterparties. That reputation sets the terms of the next operation. In DeFi every wallet starts from zero on every swap. A wallet with ten years of clean history looks identical to one created five minutes ago.

Retail users absorb that gap as inconvenience. For institutions it blocks participation. A regulated fund, a market maker, or a European protocol under MiCA cannot operate where it cannot show that counterparties meet due diligence. Regulators require that evidence. It is a condition of existence.

The relevant split is controlled liquidity versus uncontrolled liquidity. The goal is more capital in the pool, under terms an institution can defend.

Institutions stay out of DeFi when they cannot tell clean liquidity from tainted liquidity. About USD 25 billion in RWAs sit on-chain without circulating. The missing layer is the one that lets them participate with regulatory certainty.

### 1.1 Why existing solutions fall short

The market already treats this as a real problem. Identity checks before a swap are a necessary start. They remain incomplete.

Most products run one check at the moment of the swap and issue a verdict: authorized or not. They look up a sanctions list or a KYC certificate. If the lookup is clean, the swap executes. That control has value. It stops there.

Regulators require banks to monitor behavior over time. Banks must watch patterns across sessions, catch suspicious activity even when nobody is on a list, and act on reasonable suspicion.

A wallet can pass identity today and run forty small swaps in six hours tomorrow: classic structuring. A snapshot at swap time misses that. It also misses a new wallet funded by a high-risk address hours earlier, or a pattern that looks like an exit.

Hedi Navazan, Chief Compliance Officer at 1inch Labs: "risk assessment should be holistic, considering a variety of factors, not a single indicator such as transaction volume." That sentence names the gap AML Hook fills.

DeFi needs a running history: accumulate behavior, detect emerging patterns, and scale the response to the actual risk. Banks already choose between approve, escalate, or reject. A credit-card network does the same at the point of sale. The network queries a profile that already exists and returns an authorization. AML Hook follows that model. The off-chain engine keeps each wallet's score current in the background. The swap only reads a stored value. The chain does no heavy work, and the swap settles in the same block it would have settled without the hook.

Section 1.2 names the typologies that a single swap-time check leaves unseen.

### 1.2 How DeFi crime behaves

Traditional AML describes three stages: placement, layering, and integration. In DeFi those stages collapse into a few blocks. The DEX (decentralized exchange) is often the conversion step. The criminal's job is to make the address that touches the pool look ordinary before anyone writes that address on a list.

A static product answers one question at entry: is this address on a sanctions list, or does it hold a KYC pass? Crime in DeFi is built so that the address at entry is never the one already named. Illicit operators optimize for four properties.

**Time.** Lists and vendor files lag. An exploit wallet can reach a pool in the same hour the drain happened. OFAC (Office of Foreign Assets Control) and commercial feeds often land hours or days later. The address is still clear on Layer 1 when the cash-out is attempted.

**Distance.** Funds move through one or more mule wallets before the swap. Each hop is a new address with no SDN (Specially Designated Nationals) string and no KYC file. The origin stays off the pool. The subject the hook sees is "clean" if the only check is the subject's own row.

**Smallness.** The same bag is split into many swaps under a reporting or policy threshold: classic structuring, FATF's (Financial Action Task Force) smurfing red flag. Each ticket looks retail. The pattern is the hour, not the ticket.

**Borrowed reputation.** Funds land in a wallet that already has a clean published score, or in an institutional address whose credential is still valid. A static credential still reads as admissible. The running history records a sudden inbound, a change in size, or a change in how that address behaves.

Those four properties produce the typologies that a list or a KYC certificate leaves unreached. FATF's virtual-asset red-flag catalog already names them. The hook's job is to price or stop them at execution.

| Typology | How the crime runs | What a static list or KYC pass sees |
| --- | --- | --- |
| Exploit cash-out race | Drain a protocol. Swap the proceeds to ETH or a stable in the next minutes, before freezes and lists update. | The exploit address is often still unlisted. A KYC gate was never in front of it. |
| Fresh mule (1 hop) | Origin pays a new wallet. That wallet is the one that swaps. | The mule has no SDN match and no history. A gate that inspects only the subject's own row treats the mule as admissible. |
| Peel chain (2+ hops) | Origin → mule → mule → pool. Each transfer peels value and breaks the obvious link. | Every address at entry is a new retail wallet. Contamination lives in the graph, not in the subject's list row. |
| Structuring | Many swaps in one window, each under $1,000 or under $15,000, so no single ticket trips a size rule. | Each swap is small and "clean." The hour is what exceeds the institutional floor. |
| Clean-wallet overlay | A published-clean bag receives a large inbound, then swaps. The score row is still zero. | The credential and the last score are green. The inbound is the signal. |
| Mixer-adjacent entry | Tornado, Railgun, or a similar pool → fresh wallet → swap. | The new address is empty. The origin cluster never stands at the pool entry. |
| Compromised key | An attacker uses an institutional wallet that still holds a valid pass. Size and counterparties change in one session. | The KYC certificate is still good. The list is still clear. |
| LP (liquidity provider) placement | Tainted tokens are deposited as liquidity, or a sanctioned wallet tries to exit the book. | A swap-only screen never runs. The pool would otherwise warehouse the proceeds. |
| Wash and self-cycle | Repeated swaps with no economic purpose: fake volume, hide size, or mark a token before an exit. | Each leg can pass a binary allow. The running history records a circular pattern. |

A static solution is the right first layer. It stops the address already on OFAC. The mule, the peel, the structured hour, the overlay on a clean score, and the race before the list moves remain behavioral crimes. They need a running history, N-hop attribution, USD size in a window, and a third exit: extra fee into escrow, when the law still permits the swap to settle.

### 1.3 Why now

Institutional capital in DeFi is still early. When it arrives at scale, the scenario behind Standard Chartered's long-term UNI view, it will need this infrastructure.

In July 2026 Uniswap Labs published Permissioned Pools, its native access-control product. Compliance on Uniswap v4 is now a protocol priority. Labs covers who may enter the pool. AML Hook covers how those addresses behave after they are in.

### 1.4 Control at the point of execution

A bank detects a suspicious payment, analyzes it, files a SAR (Suspicious Activity Report), and sometimes freezes the account. All of that happens after the funds have moved. The control is documentary and retroactive. It works because the bank knows the client, holds documents, and can freeze the account.

That infrastructure is absent on-chain. When the hook runs before the swap, the transaction is pending. If the hook allows the swap, the block confirms and the assets move in the same block. There is no review window and no account to freeze later. The intervention that still works is the one that runs before confirmation.

The hook's job is that moment before confirmation: act on a specific swap, with the public graph of the addresses involved, before settlement. A bank that learns its client received ransomware proceeds often learns it days later. The hook can see the same public trail in the same block.

Three uses follow.

**Screening at execution.** An SDN match is checked before the swap. The integrator gets evidence that every transaction was evaluated as it ran.

**Exposure granularity.** A bank sees its client's address. The hook can also see where the funds came from and how many hops separate them from a designated address, at the moment the order executes.

**Immutable trace of the control.** The fact that the hook evaluated the swap is recorded on-chain. For an audited integrator, that record is due-diligence evidence recorded on-chain, available without reliance on an internal database.

The hook acts on what it can see on-chain, at execution. The hook leaves swap output and user principal with the user. FeeEscrow holds only the extra risk fee (section 8.3). Every evaluated swap leaves an immutable record. The reporting path (section 8.2) and the Compliance Officer Agent (section 7) turn that record into the operator's compliance file, including the documentation of a suspicious operation when the score and the facts support it. Institutional integrators on Uniswap v4 need that control at execution. Nothing in the protocol provides it natively today. The accompanying use case is built on that gap.

## 2. The Product

### 2.1 What it is

AML Hook is a modular compliance layer that runs as a Uniswap v4 hook. It checks every swap at the pool, in real time.

On swaps it intercepts two moments: before the swap and after the swap. It screens the resolved end-user, reads a behavioral score, and decides whether the swap executes, pays an extra fee into escrow, or reverts. A reporting path then turns those decisions into an audit trail.

The same hook intercepts liquidity add and remove. Those calls resolve the LP the same way a swap does when the caller is a trusted router (`IMsgSender.msgSender()`); a direct caller is the LP. Liquidity uses its own Layer 3 (`LpPolicyLib`), not the swapper `RiskPolicy`. A wallet on the OFAC / Layer 1 list, or with a published score of 71–100, cannot add. A published score 31–70 pays a 3% / 8% risk fee on the deposit (score band, not USD). A never-scored add reuses swap Floor A / C / D (including $15,000 revert). On a blocked remove the LP receives nothing in that transaction: principal and `feesAccrued` sit in FeeEscrow for 48 hours. Checkpoint 2 reads the list and the oracle. If nothing is confirmed the principal returns to the LP and the fee goes to LpCompensationVault. If a later oracle write or list hit confirms a sanction, recover books ComplianceTreasury `LP_PRINCIPAL` and `ILLICIT_RISK_FEE` separately. An emergency pause stops swap evaluation and leaves a **clean** LP mint or exit available. A listed wallet still cannot add. When the sanction is lifted and the score is out of the revert band, the same withdrawal succeeds.

### 2.2 Objectives

**Stop sanctioned and high-risk cash-outs in the pool.** Nobody on OFAC, FATF, or local lists operates in a configured pool. Every swap leaves on-chain evidence of the screen.

**Lower regulatory exposure.** Operators can show active sanctions and behavioral controls to the SEC (Securities and Exchange Commission), CFTC (Commodity Futures Trading Commission), FinCEN (Financial Crimes Enforcement Network), MiCA, and peers.

**Open the pool to institutional LPs.** Funds that cannot sit in anonymous pools get a venue where counterparties are evaluated on every swap. This matters most for RWA pools, where the underlying asset already carries transfer restrictions.

**Keep LPs off the laundering path.** A listed or 71–100 wallet cannot add. Known 31–70 pays a risk fee on the mint (3% / 8% by score). Never-scored adds use the same USD floors as a never-scored swap (Floor A / C / D). On a blocked remove the LP's principal and fees sit in FeeEscrow for 48 hours rather than arriving in-transaction. If Checkpoint 2 leaves the case unconfirmed, principal returns to the LP and the fee goes to LpCompensationVault. If the list or oracle (≥ 71) confirms, recover books `LP_PRINCIPAL` and `ILLICIT_RISK_FEE` separately, always to treasury. Pause stops swaps and leaves a clean mint or exit available.

**Price intermediate risk and create a new revenue line.** The hook prices residual risk that the pool would otherwise absorb for free. The pool keeps its standard LP fee on every swap that executes. On a fee-override, only the extra risk slice goes to FeeEscrow (section 8.3). That differential is revenue for assuming the risk of letting a medium-risk swap settle. If the wallet is later confirmed clean, the slice is released as retroactive LP compensation. If a sanction or illicit typology is confirmed, the slice stays blocked in escrow for the audit file and is then recovered to the compliance reserve. LPs sit outside that recovery path. Clean wallets pay the standard fee.

## 3. How it works

### 3.1 Swap lifecycle

The hook evaluates the end-user of the swap. It reads that address from a trusted router. It ignores Uniswap hook data as a source of identity. Swap output stays with the user.

| Moment | Action |
| --- | --- |
| Before the swap | Resolve the end-user. Run sanctions, read the score, decide. A revert cancels the swap before funds move. Allow and fee-override leave the pool at its standard LP fee. Fee-override is remembered for after the swap. |
| After the swap | Update local activity and the last seen balance. Emit the audit event. On fee-override, take only the extra risk slice into FeeEscrow. The subject remains the end-user already resolved; user principal remains with the user; this callback leaves the swap confirmed. |

### 3.2 Four layers

If Layer 1 hits, the swap (or LP add/remove) reverts and Layers 2–3 are not read. If Layer 1 is clear, Layers 2 and 3 still run even when the score is missing or stale. That is what the latency floors cover.

| Layer | Name | Function |
| --- | --- | --- |
| 1 | Static sanctions | Is this address on OFAC or another list? Match → immediate block. No external call at execution. |
| 2 | Behavioral score | Off-chain engine. Graph, frequency, mixers, structuring, layering. The score is pre-computed. The hook only reads it. |
| 3 | Decision | Swaps: `RiskPolicyLib`. LP adds: `LpPolicyLib` (known score ignores Floor B; never-scored reuses A/C/D). Maps layers 1 and 2 (plus the latency floors in section 8.4) to allow, extra fee, or revert. |
| 4 | Profile update | After the swap, emit what happened so the off-chain engine can update the wallet before the next swap. |

### 3.3 Three outputs

Existing hooks are binary: allow or block. AML Hook has a third exit.

| Score | Output | Why |
| --- | --- | --- |
| 0–30 | Allow at the standard fee | No sanctioned exposure, no anomalous pattern. |
| 31–54 (no keeper fee) | Fee-override at 3% | Atypical behavior without a confirmed sanction. |
| 55–70 (no keeper fee) | Fee-override at 8% | Same band family; keeper may still send an explicit `feeBps`. |
| 71–100 or OFAC | Revert | Confirmed exposure. No discretion. |

Medium risk is the product difference. Regulatory practice for that band is monitoring and friction. The escrowed extra fee is that response, and it is also the hook's revenue for assuming residual risk. The slice is deposited in FeeEscrow on that swap. Paying LPs with still-suspect funds would make them instruments of money launderers. Later clean releases go to LpCompensationVault for LP claim. A confirmed sanction is recovered to ComplianceTreasury, then paid to an allowlisted authority. LPs sit outside that payout path. See section 8.3.

**Score 31–70.** The legal duty is to monitor and report. Banks apply the same FATF risk-based approach: enhanced due diligence, with rejection reserved for cases the law requires.

**Sanctioned or score 71–100.** Unconditional block **on swaps**. Liquidity: cannot add. On remove that wallet receives nothing in-transaction: principal and fees wait 48h in FeeEscrow; illicit recover splits treasury accounts; clean principal returns to the LP.

When the keeper has not written, the score is stale, or a large inflow is still unpublished, those three bands are incomplete. Section 8.4 lists the extra floors and every numeric threshold.

### 3.4 A running history

Competitors check a credential or a list at the instant of the swap. AML Hook keeps a running history of each wallet.

Every successful swap emits an event. The scoring engine folds in amount, timing, and relation to the prior pattern. The next swap reads a score that already includes the last one.

A wallet can start low and rise because of on-chain behavior, with no list entry. The engine looks for structuring, layering, dust, co-spending, and already-known clusters.

### Threats the hook is built to see

Section 1.2 is the crime model. The hook maps those typologies onto three families it can act on at execution.

**Origin of funds and sanctions.** OFAC / FinCEN / FBI matches on Layer 1. New wallets funded from known attack infrastructure. Mixer clusters (Tornado Cash, Railgun). Multi-hop contamination two to four transfers from the origin, with the decay in the use case. Distance is priced: 1 hop is punitive (≈65 / 8%), 2 hops are proportional (≈42 / 3%).

**Market conduct.** Wash trading and self-cycles; rug pulls and exit liquidity; layering: chained swaps that hide the route. Structuring is the same family when the aim is to dodge a reporting or policy threshold. Mitigation C and the unknown-wallet USD window are the on-chain form of that red flag.

**Real-time threats.** Named-address OFAC: Layer 1 `SanctionHit` when `SanctionRegistry` lists an address (score not read). The COA (Compliance Officer Agent) can write that mapping from a live OFAC SDN exact-address match; `beforeSwap` only reads the mapping. That is hook functionality, not a use-case wallet. Wallet A is **unlisted**: the officer writes score 100 from an external exploit finding (`WalletBlocked` / `SCORE_REVERT_BAND`). P2P (peer-to-peer) from A still contaminates B, C, and D. Exploit cash-out before a keeper write: Wallet E (never written, starts empty, funded only by clean C). Clean-wallet overlay: Wallet D's inbound-USD bands (pass / 3% / 8%). Compromised keys: an institutional wallet still has valid credentials, and the attacker uses them. The signal is a sudden change in size or counterparties.

A static list reaches only the named-address slice of the first family. Graph, conduct, and the race against the list need the cumulative model.

## 4. Legal and regulatory framework

### 4.1 Applicable frameworks

| Framework | How AML Hook uses it |
| --- | --- |
| OFAC / SDN | Layer 1 query. Match → unconditional block. |
| FATF Rec. 15 (virtual assets) | If the operator has a point of control, VASP (Virtual Asset Service Provider) duties can attach. The hook is built to that baseline. |
| MiCA | KYC and sanctions for European VASPs. Off-chain UI blocks are easy to bypass. The hook is inside the pool. |
| SEC / CFTC | Audit trail for assets that may be securities. |
| GENIUS Act (2025) | Compatible with reserved payment-stablecoin expectations (Circle / USDC). |
| FATF / FinCEN monitoring | A reasonable monitoring system with a record of actions taken. Behavior is the on-chain proxy when wallet KYC is absent. |

The UHI10 prototype follows FATF as the international baseline. Operators turn on the jurisdictional layers they need without changing the core decision.

### 4.2 Operational obligations

**Source of funds (Rec. 3 / 10).** Lists plus forensics, with N-hop tracing. The output is a score with a trail, not a single bit.

**Ongoing CDD (Customer Due Diligence, Rec. 10).** Profiles update after onboarding. Enhanced due diligence has a defined internal threshold.

**Record retention (Rec. 11).** Immutable log of each decision: time, score, sources, action. Minimum five years.

**Suspicious reporting (Rec. 20).** When the score and the facts support reasonable suspicion, the hook record plus the Compliance Officer Agent produce the suspicious-operation file: typology, source of funds, hop trail, and a reasoned conclusion. A sanctions or high-score hit reverts before any delivery obligation. FeeEscrow holds only the extra risk fee.

## 5. Competitive differentiation

### 5.1 Map

The field splits into two groups.

**Static identity (binary KYC).** Civic Pass, VioletID, Coinbase Verified Pools, Uniswap Labs Permissioned Pools: hold a credential or sit on an allowlist.

**Institutional AML with off-chain data.** PureFi (amount thresholds, 15-minute score, no cumulative profile). Predicate / USDL (attestations, binary). Levery (bank KYC/KYB at before-swap, no after-swap trail, no dynamic fee).

| Competitor | When it runs | Scoring | Dynamic fee | After-swap memory | Open | Status |
| --- | --- | --- | --- | --- | --- | --- |
| PureFi | Before swap | Amount threshold | No | No | Partial | Mainnet |
| Predicate / USDL | Before swap | Static attestation | No | No | No | Mainnet |
| Coinbase Verified | Before swap | Static KYC | No | No | No | Mainnet |
| Civic Hook | Before swap | Identity | No | No | Yes | Deployable |
| Violet Hooks | Before swap | Identity | No | No | Yes | Deployable |
| Levery | Before swap | Bank KYC/KYB | No | No | No | Institutional |
| Permissioned Pools | Before swap | Issuer allowlist | Yes | No | No | Documented (Labs) |
| AML Hook | Before and after | Historical behavioral | Yes | Yes | Yes | In development (UHI10) |

### 5.2 Permissioned Pools

Labs' product is the ecosystem reference. The issuer keeps an on-chain allowlist. Before each swap and each LP action the hook allows or reverts. Restricted tokens wrap on the way in and unwrap on the way out. Position NFTs (non-fungible tokens) are non-transferable. Labs ships a permissioned router for that path. AML Hook can trust that router for end-user resolution after the same governor review as any other integrator.

It solves issuer access control: who may hold exposure to the asset. Behavioral scoring, profile accumulation, and fee calibration sit with AML Hook. A wallet that passed KYC can still layer inside the pool unseen. FATF Rec. 10 ongoing monitoring is out of scope by design.

The two products stack. Permissioned Pools governs entry. AML Hook evaluates behavior after access is granted. The permissioned router is the shared entry: Labs' path into the allowlisted pool, and a router this hook can trust without a parallel frontend.

## 6. Market

### 6.1 Size

| Layer | Name | Size |
| --- | --- | --- |
| TAM (Total Addressable Market) | Tokenized RWA | About USD 100 billion by end-2026; BCG / Ripple see USD 18.9 trillion by 2033 |
| SAM (Serviceable Addressable Market) | Mid-market private credit and non-enterprise RWA | About USD 5 billion in active on-chain private credit today; potentially USD 15 billion by 2027 |
| SOM (Serviceable Obtainable Market) | First pools | Centrifuge, Goldfinch, Clearpool and peers with live TVL (Total Value Locked) that need a compliance difference |

### 6.2 Mid-market private credit

On-chain private credit reached USD 3.2 billion in March 2026, up 180% year over year.

These issuers operate without Predicate. Maple, Centrifuge, and Goldfinch tokenize senior loans, SME (small and medium enterprise) credit, and receivables without a Paxos-scale compliance budget.

Consolidation is the gap. Centrifuge's share fell from 20.6% to 3.3%, Goldfinch from 17.6% to 2.5%. Protocols that cannot offer institutional guarantees lose ground to Maple's institutional pools.

Yields of 8%–12% versus 4%–5% on Treasuries pay for the control. A pool that can show a real AML process can defend that spread.

### 6.3 Other segments

**DeFi protocols that want institutional LPs.** BlackRock, Fidelity, Franklin Templeton cannot deposit where the counterparty may be sanctioned. They need a pool with embedded screening.

**RWA issuers.** Transfer restrictions on the underlying clash with Uniswap v4's internal balances. Permissioned Pools moves the allowlist to the pool. AML Hook sits on the next layer: behavior after access.

**MiCA DEXs.** A caller who invokes the contract directly bypasses a UI block. The hook is the native control.

**Regulated market makers.** Jump, Wintermute, Cumberland carry their own AML duties. An uncontrolled pool is their exposure.

### 6.4 Named targets

| Entity | Category | Problem |
| --- | --- | --- |
| Centrifuge | Mid-market private credit | Needs compliance to compete with Maple without a Paxos budget |
| Goldfinch | Mid-market private credit | Share loss tied to missing institutional guarantees |
| Clearpool | Mid-market private credit | Uncollateralized pools that need counterpart controls |
| Ondo Finance | Institutional RWA | Treasuries with manual allowlists |
| European MiCA operators | Regulated DEXs | No native Uniswap v4 answer today |
| Coinbase / Kraken | Exchanges with DeFi ambitions | Must keep AML standards in decentralized venues |

## 7. Compliance Officer Agent

This section is the Compliance Officer Agent. In the UHI10 demo, when
`ANTHROPIC_API_KEY` is set, Claude emits `finalScore`, `recommendedFeeBps`,
typologies, and the Opinion / STR-shaped (Suspicious Transaction Report) file. The keeper publishes the score
and fee to `ComplianceOracle`. `beforeSwap` reads that row. A–E constraints live in skill `uhi10-use-case` (`consult_skill`).
Without a key, or under `COA_LIVE=0` / tests, a skill interpreter
(`factScoring.ts`) applies the same skills. There are still no live vendor KYT (Know Your Transaction) APIs
(OFAC SDN HTTP, Chainalysis, TRM, Elliptic, Forta, EAS, Hypernative).

The hook number is the on-chain decision. The agent writes the file the operator keeps: why this swap was allowed, charged, or reverted.

A supervisor asks why transactions were blocked and wants a reasoned file. A raw count of reverts never answers that. The agent copies a human officer's process: observe, gather source-of-funds context, apply FATF / FinCEN typologies, test the legitimate hypothesis, conclude with a confidence, and write it down.

| Band | Criterion | Agent output |
| --- | --- | --- |
| Green | Low score, clean history | Minimal log |
| Yellow | Medium score, or pattern that disagrees with the score | Analysis memo |
| Red | High score or OFAC block | Full analysis and STR draft |

Yellow carries the weight. These are swaps the hook allowed that still deserve a written file. The memo is the suspicious-operation report for that case. Eight sections: address, transaction, history, source of funds with hops, typology, legitimate alternative, conclusion with confidence, recommendation.

## 8. Technical appendix

This section is the on-chain map a reviewer can check. The product and the
business case are sections 1–7. Numeric floors and FATF cites are §8.4.

Two environments. Reviewers should grade each on its own terms.

| | Guided demo | Live pool |
| --- | --- | --- |
| Chain | Anvil `31337` (local default) | Ethereum Sepolia `11155111` |
| UI / API | Next.js + `apps/api` (simulator, not the MetaMask extension). Swap card: **Advance 5 min**. Mint in the panel is 1,000 USDC / 1 ETH. Hosted API can set `ORACLE_CHAIN_ID=11155111` | Same API: faucet is `POST /demo/mint` `{ address }` (not a panel control) + keeper/COA write this chain. SDK `getDeployment` is still 31337-only |
| PoolManager | `MockPoolManager` | Official Uniswap v4 PoolManager |
| Quotes | `AmlHook.previewSwap` (demo swap card, either chain) | Real `PoolManager` fill (e.g. app.uniswap.org) |
| Addresses | `contracts/deployments/31337.json` | [`docs/Sepolia.md`](Sepolia.md) |

A new EOA against the Sepolia pool is Wallet E (no oracle row → Floor A/C/D). The demo leaves that address unpublished until an operator writes it.

### 8.1 Contract architecture

Uniswap v4 puts every pool in one PoolManager. The pool key carries a hook
address. That address must implement the Uniswap callbacks and stay under
**24,576 bytes** (EIP-170). Full evaluation plus governance exceeds that limit, so
the hook is two contracts that share one state:

```
User → Router → official PoolManager → AmlHook          ← only address in the pool key
                                         │ DELEGATECALL
                                         ▼
                                   AmlHookSatellite     ← evaluation + governor / officer setters
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
           SanctionRegistry     ComplianceOracle         RiskPolicy
                 (L1)                  (L2)                  (L3)
                                         │
                                         ▼
              AmlHookSettlement → FeeEscrow → (later) ComplianceTreasury
```

| Address | What a reviewer should see |
| --- | --- |
| **AmlHook** | Thin CREATE2 shell. Uniswap calls only this address (`beforeSwap` / `afterSwap` / add / remove, plus return-delta flags so the hook can `take` extra fee or seize an LP exit). It owns storage and settlement. |
| **AmlHookSatellite** | Evaluation and governance bytecode. Uniswap never calls it. The hook `DELEGATECALL`s it: the satellite's code runs, but every read/write hits **the hook**. One state. Not a second oracle and not a second list. |
| **SanctionRegistry** | Layer 1 list. A hit stops the swap or LP add before the score is read (`SanctionHit`). |
| **ComplianceOracle** | Layer 2 store. `_ORACLE_KEEPER` submits `updateScore`; a distinct attestor signs `attestationHash` (must include that block's `block.timestamp`). The hook never writes this. |
| **RiskPolicy** | Layer 3. Pure mapping. The hook **calls** `decide` on swaps. Same library as off-chain preview. |
| **LpPolicy / LpPolicyLib** | Layer 3 for liquidity. Known score ignores Floor B. Never-scored reuses swap A/C/D. |
| **FeeEscrow** | 48h hold of the extra risk fee and of a seized LP exit. Own owner / keeper. AccessManager is a separate authority box. |
| **ComplianceTreasury** | Two ledgers after illicit recovery: `LP_PRINCIPAL` and `ILLICIT_RISK_FEE`. They cannot mix. |
| **AccessManager** | Shared authority for keepers, governor, and compliance officer. |

`DELEGATECALL` is why inheritance order is a review fact, not a style note.
The satellite's first slots are AccessManaged / Pausable, then
`sanctionRegistry`. The hook must declare the same prefix: **Activity →
Governance → Settlement last**. A reversed list put `complianceTreasury` in
the `sanctionRegistry` slot. Every guard then called `isSanctioned` on the
treasury and reverted. That happened on an earlier Sepolia hook (`0xf558…`).
The live hook is in `docs/Sepolia.md`. The unit test
`AmlHook.StorageLayout.t.sol` locks slot 1 = `sanctionRegistry`.

**What runs on each Uniswap callback**

| Callback | Hook (this address) | Satellite (`DELEGATECALL`) |
| --- | --- | --- |
| `beforeSwap` | Dispatch only | Resolve subject → L1 → L2 → USD quote → `RiskPolicy.decide`. Cache the decision. |
| `afterSwap` | `take` extra fee → FeeEscrow if FEE_OVERRIDE | Close the cache, update activity / USD window, emit the audit event |
| `beforeAddLiquidity` | Cache the LP subject | L1 + known-score `LpPolicyLib`. Listed or 71–100 cannot add. |
| `afterAddLiquidity` | Full 3%/8% `take` into FeeEscrow on FEE_OVERRIDE | Never-scored A/C/D once token deltas exist (empty-pool mint ≈ 100% impact) |
| `beforeRemoveLiquidity` | Cache seize / allow | L1 or score ≥ 71 → seize (pause stays idle) |
| `afterRemoveLiquidity` | Seize principal + fees into FeeEscrow 48h | n/a |
| Unknown selector (`fallback`) | Forward | Governor / officer setters, `previewSwap`, `observeSwap` |

On add, pause leaves a clean mint available. On remove, a listed or 71–100
wallet proceeds without a revert: the hook takes the full delta. Principal and
`feesAccrued` go to FeeEscrow (Active, kinds `LpPrincipal` / `RiskFee`).
Checkpoint 2 reads the list and the oracle. No keeper bool.

A never-scored first mint on an empty pool is 100% impact. Floor A mid takes
8%; `PoolManager.take` reverts if the manager holds nothing. The first
Sepolia seed needed a published 0–30 row on the **untrusted**
liquidity caller (`PoolModifyLiquidityTest`), not on the LP EOA. That write
is an operator seed, not a finding that the test router is a clean trader.

**Who may write what**

Two authority boxes. Sanctions, the score store, and hook settings sit on a shared AccessManager (keepers, governor, compliance officer). FeeEscrow has its own owner, keeper, depositor, and auditor. The risk policy is a pure mapping: no roles. The hook itself has no extra role: Uniswap callbacks plus settlement `take`. Evaluation lives in the satellite.

| Role | May | May not |
| --- | --- | --- |
| Admin | Grant and revoke the four operational roles | Write scores, sanctions, or escrow day to day |
| Registry keeper | Add sanctions (`commitSanction`, then `revealSanction` after **10 blocks** minimum; emergency `setSanctioned` is immediate); delist immediately | Publish scores, pause the hook, touch escrow |
| Oracle keeper | Submit a score update **with** a valid attestor signature | Sign the payload alone; write the sanctions list; move escrow |
| Attestor | Sign the score payload (wallet, score, hop, origin, fee, time, chain) | Submit the transaction alone |
| Hook governor | Operational thresholds (staleness, activity, daily window, inflow share), price feeds, trusted routers and multisigs, pause, attestor rotation, rate limit, reveal delay | Write scores, sanctions, or policy knobs (USD floors / floor fees / pool-impact) |
| Compliance officer | Propose then confirm USD floors, floor fees, and the pool-impact cut (48-hour delay). The $1,000 fee floor cannot be lowered. Related pairs keep the upper value strictly above the lower | Write scores, sanctions, trusted routers, or score cuts (31 / 55 / 71 stay fixed) |
| Escrow owner | Appoint keepers, the LP fund, and the compliance reserve; recover blocked rows after 7 days, only to treasury (by kind) | Deposit fees or principal |
| Escrow depositor (the hook) | Deposit the extra fee, LP-add risk fee, and seized LP principal | Release or block rows |
| Escrow keeper | Release or block after off-chain review | Change owner or write scores |
| Auditor | Read the full escrow row | Move tokens |

Deploy requires admin, registry keeper, oracle keeper, hook governor, compliance officer, and attestor. The attestor cannot be zero and cannot collide with the governor or either keeper. The officer grant carries a 48-hour execution delay.

A new sanction uses commit-reveal (`MIN_REVEAL_DELAY` = 10 blocks) so the address is not visible in the mempool before the flag lands. Delisting is immediate. `setSanctioned` remains for emergencies.

**What each contract does**

| Contract | Job | Does not |
| --- | --- | --- |
| AmlHook | Uniswap callbacks; own storage; `take` into FeeEscrow | Compute the off-chain score; hold the sanctions list |
| AmlHookSatellite | Evaluation + governance **in the hook's storage** | Own a second copy of that state; receive Uniswap callbacks |
| AmlHookLogic (inside the satellite) | Read sanctions, score, policy, and USD prices; emit swap events; apply latency floors | Compute the behavioral score off-chain; take tokens |
| AmlHookSettlement (on the hook) | Take the extra fee and seize a blocked LP exit | Decide allow / fee / revert |
| Sanctions registry | Layer 1 list | Score wallets |
| Compliance oracle | Store the keeper-written score, hop, origin, fee, and timestamp | Decide the swap |
| Risk policy | Map swap score + floors + USD size → allow / fee / revert | Store anything |
| LP policy | Map LP score (no Floor B) or never-scored A/C/D → allow / fee / revert | Decide swaps |
| FeeEscrow | Hold the extra fee and seized LP principal for 48 hours | Change the pool LP fee |
| LpCompensationVault | Receive clean risk-fee releases; LPs claim per closed epoch against a merkle root of shares at the risk-assumption blocks | Receive illicit recovers; pay a listed or score ≥ 71 wallet |
| ComplianceTreasury | Two ledgers: `LP_PRINCIPAL` and `ILLICIT_RISK_FEE`. Delayed allowlisted payouts to an authority destination | Mix the two accounts; pay the LP vault |
| Oracle keeper / COA | Off-chain analyst and publisher | Write FeeEscrow or run inside the swap |

FeeEscrow destinations are two distinct addresses. The extra fee stays in FeeEscrow until a clean release or an illicit recovery. Sending it to LPs on the same swap would make them take proceeds of a still-suspect flow. Every clean **risk-fee** exit (early release, clean checkpoint, or default after 48 hours) goes to `LpCompensationVault`. A keeper closes an epoch with a merkle root of LP shares at the risk-assumption blocks; each LP claims. A listed or score ≥ 71 wallet cannot claim. Unclaimed pot recycles into the next open epoch after 90 days. A clean **LP-principal** row still pays the LP wallet directly. Checkpoint 2 reads `SanctionRegistry` and `ComplianceOracle` (list hit or score ≥ 71) and takes no keeper bool. A confirmed-illicit row stays blocked in escrow while the operator produces the file, then owner recovery (7-day floor) or permissionless recovery (default 90 days) sends it to ComplianceTreasury: `ILLICIT_RISK_FEE` for risk-fee rows, `LP_PRINCIPAL` for seized capital. The officer then `proposePayout` / `executePayout` (48-hour delay) to an allowlisted authority destination. The vault and the pool sit outside that payout path. Those two treasury accounts cannot be mixed. The vault and the treasury cannot be the same address. Ownership is two-step and starts as the admin or a dedicated escrow owner, not the deploying key. The hook is registered as depositor once at deploy, then that bootstrap key is cleared.

**Read path before the swap.** PoolManager calls **AmlHook**. The hook
`DELEGATECALL`s the satellite. The satellite then:

1. Resolves the end-user through the trusted router only. Hook data is unused as identity.
2. Checks the sanctions list. A failed or missing check blocks the swap (fail-closed).
3. Reads the wallet's stored score on `ComplianceOracle`.
4. Derives three signals from pool-local state: whether the score is stale, how much activity the wallet has had in the current window, and any inflow not yet reflected in the score. It converts this swap plus the running window to USD (`lastFx` if younger than 30 minutes; otherwise one Chainlink round per token).
5. Calls `RiskPolicy.decide` on that combination of score and signals.

The exact USD thresholds for each case (unknown wallet, published-clean wallet with a new inflow, no live round and no `lastFx` within 24 hours) are in the master decision table, section 8.4. A revert is a custom error; how reverted swaps are logged and indexed is covered in section 8.2.

**Write path after the swap.** Update activity and the USD window, refresh the last seen balance, emit the audit event. On fee-override, take the extra slice and try to deposit it. A failed deposit leaves the swap settled; the amount is credited so the user can claim it or anyone can retry later.

**Between swaps.** The keeper publishes scores. Score writes originate off-chain. Trusted routers, multisigs, and price feeds are governor work. USD floors, floor fees, and the pool-impact cut are compliance-officer work (propose, then confirm after 48 hours). Both sit off the swap path.

**Fallback.** A last published row is used only when `updatedAt > 0`. A wallet the keeper has never written (`updatedAt == 0`) is unknown: Mitigation A, distinct from a silent-oracle ALLOW. The USD price feed is separate: `lastFx` younger than 30 minutes skips Chainlink; otherwise one round per token, cached. If this block has no usable live round, the hook multiplies this swap's amounts by that last price, until the cache is older than 24 hours. Only then does a missing feed fail-close. The score store and the token/USD feed are separate.

**Smart accounts and routers.** Institutional funds use Safes. The address the pool sees is often the router, not the user. Scoring a **trusted** router would either bless every swap or block the pool. The hook treats a trusted router as infrastructure, never as the subject.

Subject resolution has one path. The governor maintains a trusted-router list. When the initiator is trusted, the hook asks that router for the end-user. An ordinary wallet is accepted. A contract is accepted only if it is a trusted multisig whose owners pass the sanctions check (all clean, or any clean, as configured). Hook data cannot declare the user.

- **Swap.** If the router is untrusted, or the lookup fails, the swap reverts before any layer runs (`MissingSwapSubject`).
- **Liquidity.** An untrusted caller **is** the subject. On Sepolia the first mint used Uniswap's `PoolModifyLiquidityTest`, not the LP EOA. A never-scored mint on an empty pool is 100% impact: Floor A can take 8% and `PoolManager.take` reverts until a 0–30 oracle row exists for that caller.

Owner screening on-chain is sanctions only. After owners pass, the subject remains the Safe. The hook reads the Safe's own score row. When the keeper computes that row, a signer with no history must pull the aggregate up. An unscored signer is treated as unknown, the same way Wallet E is treated.

### 8.2 Reporting

After each successful swap the hook emits a structured event: address, amount, time, score, decision, fee. When USD came from a heartbeat-stale live round or from `lastFx` after a failed live read (distinct from the 30-minute hot cache), it also emits `PriceFallbackUsed`. The prototype indexes those events in the API in-memory log (`GET /events`). Production can point The Graph at the same ABI; what matters is the hook's decisions, not the indexer.

Reverted swaps leave those events unemitted. Index the error on the failed transaction instead.

### 8.3 Fee escrow

On fee-override the pool keeps its standard LP fee. After the swap, only the extra slice is taken and deposited for 48 hours. User output settles in the same block. Escrow holds the extra risk slice, never the full swap.

That slice is a new revenue line. The hook let a medium-risk swap settle. The protocol assumed the residual risk. The differential is the price of that assumption. It belongs in FeeEscrow, not in the pool.

Sending the extra fee to LPs on the same swap would pay them with funds that may still be illicit. LPs would then earn from the flow they were meant to stay clear of. That would make them instruments of money launderers. The liquidity path carries the same objective from the other side: a sanctioned or 71–100 wallet cannot add, and on a blocked remove that wallet's principal and fees stay in FeeEscrow for that transaction.

The Compliance Officer Agent reviews the case off-chain. The agent has no escrow write path. A dedicated escrow keeper submits the on-chain call after a sanity check on the agent output.

| Moment | Action | RiskFee destination | LpPrincipal destination |
| --- | --- | --- | --- |
| 0–24h | Optional review | Still held | Still held |
| 24–48h | Early release | LpCompensationVault (LP claim after epoch close) | LP wallet |
| At 48h, list or oracle score ≥ 71 | Block | Stays in escrow for audit; after the recovery delay → ComplianceTreasury `ILLICIT_RISK_FEE`, then delayed authority payout | Same hold; recover books `LP_PRINCIPAL` |
| At 48h, not illicit | Release | LpCompensationVault | LP wallet |
| Nobody resolved by 48h (and still not illicit on-chain) | Default release | LpCompensationVault | LP wallet |

When the list or a later oracle write confirms a sanction or an illicit typology, the escrowed slice stays blocked for audit. It remains outside LP yield. Tokens remain in FeeEscrow so the operator can produce the file. The escrow owner (a Safe in production) is the authority that may later recover a blocked row: `recoverBlocked` waits at least 7 days and can go only to ComplianceTreasury, which books `ILLICIT_RISK_FEE` (`ComplianceCredited`). After the full configured delay (default 90 days), anyone may call `recoverExpiredBlocked` to the same account. The destination remains ComplianceTreasury. The LP fund and the pool sit outside that path. `FeeRecovered` records destination, token, amount, wallet, and the originating fingerprint so the movement is auditable against the fee-override swap or the seized LP exit.

Early release refuses if the oracle or list already marks the wallet illicit (`IllicitOnChain`). Default release does the same: it blocks instead of paying the LP fund.

If the deposit fails, the swap still settles. The extra tokens are tracked so the subject can claim them or anyone can retry the deposit. Other skip reasons emit a skip event and take nothing.

The extra fee is a real cost even when the first filter allowed the swap. When the wallet is later confirmed clean, that cost is released as LP compensation for risk already taken on a swap that turned out clean. It is compensation for risk already assumed, distinct from a live share of a still-suspect fee.

### 8.4 Oracle latency

The behavioral score is computed off the swap path. The engine runs off-chain. A keeper writes the result into `ComplianceOracle`. The swap itself adds no wait.

**When the oracle row moves.** Three clocks, on purpose shorter than Floor B so a healthy writer never looks late:

| Clock | Interval | Who writes `ComplianceOracle` | If the agent is absent |
| --- | --- | --- | --- |
| COA evaluation | Event-driven (seed, P2P, swap). Duration = Claude or skill-interpreter runtime. Demo `POST /transfers` and `POST /swaps` wait for this write. | `_ORACLE_KEEPER` after the agent emits `finalScore` / `recommendedFeeBps` | No new facts. The last published row stays. |
| Keeper heartbeat | **3 minutes** (`KEEPER_TICK_MS`, default 180_000). Leaves the agent uncalled. Republishes the last score so `updatedAt` stays fresh. | Same keeper + attestor | Floor B stays quiet on a stable wallet for as long as this tick runs. |
| Floor B arm | **5 minutes** (`stalenessThreshold` / `MAX_SCORE_AGE`; contract and local-deploy default) | Nobody: the hook treats the existing row as stale | Published-clean wallet pays Floor B friction until a write lands. |
| Never written | `updatedAt == 0` | Nobody | Floor A (unknown wallet), not B. Wallet E is this path by design. |

The 3-minute tick is shorter than the 5-minute stale window so a retail keeper that is only stamping freshness stays inside the freshness window between honest writes. Busy institutional pools that write every 30–60 seconds can tighten Floor B to 120 seconds (`setStalenessThreshold`). The floor has a lower bound near 120 seconds: validators can nudge `block.timestamp`. If both the agent and the tick are down (or slower than 5 minutes), Floor B is the intended lag, distinct from a contamination finding. The oracle allows 24 `updateScore`s per wallet per hour so a 5-minute stamp plus a few real tier changes fit.

The hook treats a published score as stale once `updatedAt` is older than `stalenessThreshold`. The hook governor retunes it per pool (`setStalenessThreshold`, 1 second to 24 hours).

Sanctions writes are event-driven. A new hit uses commit-reveal (minimum **10 blocks**; the governor may raise `revealDelay` and may not lower it). Delisting is a single call. `setSanctioned` is the emergency path.

A structural gap remains. If a transfer changes risk and the keeper has not written yet, the next swap can read a stale or missing score. The hook keeps a little pool-local state and passes derived signals into the policy: stale, operation count, significant inflow, never scored, assessed USD, inbound USD. The policy stays a pure mapping. USD quotes happen in the hook before the decision.

#### Master decision table

A single table replaces every condition that determines a swap's outcome: the published score, the latency floors, and the state of the price feed.

| Condition | Layer / floor | Outcome | Fee |
| --- | --- | --- | --- |
| Address on the sanctions list | Layer 1 | REVERT add / seize remove | `SanctionHit` on add; remove escrows principal + fees 48h |
| Published score 0–30, fresh, no active floor | Score band | ALLOW | Pool standard, 0.30% |
| Published score 31–54 (keeper omitted an explicit fee) | Score band | FEE_OVERRIDE | 3% (~2 hops) |
| Published score 55–70 (keeper omitted an explicit fee) | Score band | FEE_OVERRIDE | 8% (~1 hop) |
| Published score 71–100 | Score band | REVERT | `WalletBlocked` |
| Wallet never written (unknown), assessed USD < $1,000 | Floor A | FEE_OVERRIDE | 3% (8% if the swap is more than 20% of the pool's active liquidity) |
| Wallet never written, assessed USD $1,000–$14,999 | Floor A mid | FEE_OVERRIDE | 8% (REVERT if the swap is more than 20% of the pool's active liquidity) |
| Wallet never written, this swap ≥ $15,000 | Floor A large | REVERT | Blocked by magnitude |
| Score older than `stalenessThreshold` (default 5 minutes), **0** swaps in the hour | Floor B first | FEE_OVERRIDE | 3% (8% if the swap is more than 20% of the pool) |
| Score older than `stalenessThreshold` **and** ≥1 swap in the hour, assessed USD (this swap + hour) under $1,000 | Floor B dust | ALLOW | Pool standard, 0.30% (3% if the swap is more than 20% of the pool) |
| Same Floor B trigger, assessed USD $1,000–$14,999 | Floor B mid | FEE_OVERRIDE | 3% (8% if the swap is more than 20% of the pool) |
| Same Floor B trigger, assessed USD ≥ $15,000 | Floor B large | FEE_OVERRIDE | 8% (pool-impact extra leaves this at 8%) |
| Prior 24h USD > 0 and prior + this swap ≥ $15,000 (any wallet) | Floor C | REVERT | `DailyAggregationBlocked` |
| Published-clean wallet, inbound USD under $1,000, score still older than the baseline | Floor D dust | ALLOW | Pool standard, 0.30% |
| Published-clean wallet, inbound USD $1,000–$14,999, score still older than the baseline | Floor D mid | FEE_OVERRIDE | 3% |
| Published-clean wallet, inbound USD ≥ $15,000, score still older than the baseline | Floor D large | FEE_OVERRIDE | 8% |
| No live Chainlink round and no `lastFx` within 24 hours | Price feed guard | REVERT | Fail-closed |

Notes on reading the table:

- A published score of 0 (Wallet D in the use case) and a wallet that was never written (Wallet E) are different rows. Floor A no longer applies once a score exists, even if that score is 0. Floor D **does** apply to a never-written wallet: with no baseline the current input-token bag is inbound (pass / 3% / 8%). The stricter of A (swap size) and D (bag) wins. A may still revert on swap size or on a high pool-impact mid-band swap. Demo E starts empty; clean C funds it (no hop). Wallet E is funded from clean C. Funding from A (exploit origin / score 100) would contaminate the demo path.
- Layer 1 `SanctionHit` is distinct from a score-band revert. A listed address fail-closes before the oracle is read. Wallet A (`WalletBlocked`, score 100, mapping clear) is the contrast: exploit finding, not an OFAC listing.
- Floor B and Floor D map to allow or extra fee. Floor A large reverts on this swap. Floor C reverts when several swaps in 24 hours cross $15,000. B and D use the same USD cuts as A ($1,000 / $15,000) but map them to pass / 3% / 8%. B's 20% pool-impact extra hardens the fee band and stops at 8%. D has no pool-impact extra.
- **Liquidity never-scored** reuses this same Floor A / C / D table. Floor A is this deposit vs $1,000 / $15,000 (3% / 8% / revert), including the 20% pool-impact extra. Floor C is the 24-hour **sum of adds** (`_lpDaily`), never mixed with swap C. Floor D uses the same `Inflow` baseline as a swapper (max USD of token0 / token1). A never-scored add leaves Floor B unarmed, and a **published** LP score ignores Floor B: 0–30 stays 0 extra even if stale; 31–70 pays 3% / 8% by score, not USD.
- A score-band revert or a fee-override already set by the score remains in force when a floor also applies.
- A working price feed is unused when the wallet is published-clean, has no new inflow to quantify, and Floor B is not sizing a window (the first stale swap of the hour charges 3% without a quote). When a quote is required, the hook uses `lastFx` if that round is younger than 30 minutes (`FX_HOT_TTL`) and skips Chainlink. Otherwise it reads the feed once per token and reuses that price for every amount in the swap (ticket, inbound, bag, settled size, window add). A heartbeat-stale live round is still a price: it is used and stored. An unbound or reverting feed uses `lastFx` until 24 hours. `PriceFallbackUsed` records heartbeat-stale live rounds and the 24-hour cache path, omitting the 30-minute hot cache.

**How the USD thresholds are computed.** Figures use 8 decimals. The pool's base fee on an executing swap is always 0.30%. When the override is higher, escrow holds the difference. The compliance officer retunes the USD floors, floor fees, and pool-impact cut named in the "Who retunes what" table below (48-hour delay). Score cuts 31 / 55 / 71 and `MAX_OVERRIDE` stay fixed in the policy.

**Why each floor exists: operation and normative basis**

Citations sit in the body (this paper has no footnote apparatus). The compliance officer can retune the dollar cuts; the hook governor retunes the 24-hour window. The FATF sources below are why those defaults exist, not a claim that FATF published a Uniswap hook.

**A. Never-written wallet.** A raw unread score of 0 would look like allow. Unknown is a missing write. **This swap** then decides 3%, 8%, or revert. Structuring across the day is Floor C. If the same swap takes more than 20% of the pool's active liquidity (compliance-officer retunable, 48-hour delay), 3% becomes 8% and 8% becomes a revert. Once the keeper publishes, including a clean 0, this path turns off.

The $1,000 cut is the FATF virtual-asset threshold. The Updated Guidance for a Risk-Based Approach to Virtual Assets and VASPs (2021), note 37, states that FATF agreed to lower the occasional-transaction threshold for virtual assets to USD/EUR 1,000 because of the higher ML/TF risk of their cross-border nature: "The FATF agreed to lower the threshold amount for VA-related transactions to USD/EUR 1,000." That cut is stricter than the general banking floor by design.

The $15,000 cut is Recommendation 10's general occasional-transaction CDD floor for traditional financial institutions (USD/EUR 15,000).

The 20% pool-impact extra is a risk-based design choice rather than a FATF figure. Institutions must consider all relevant risk factors, including product, service, transaction, and delivery-channel factors (Interpretive Note to Recommendation 10). Liquidity concentration in a pool is a DEX-specific factor with no direct banking equivalent, so it stays a compliance-officer parameter, not a fixed legal number.

**B. Stale score.** A published score older than `stalenessThreshold` arms Floor B. If this is the first swap of the hour (`operationCount == 0`), the policy charges 3% (8% if the swap is more than 20% of the pool). If the wallet already swapped in the hour, size of this swap plus the hour window then decides: under $1,000 → pass; $1,000–$14,999 → 3%; $15,000 or more → 8%. If that same swap takes more than 20% of the pool, the band hardens (pass → 3%, 3% → 8%) and stops at 8%. B maps to allow or extra fee. The floor turns off when the hour resets or when a new `updateScore` moves `updatedAt`.

The arming condition, a score that exists but was not refreshed, sits on Recommendation 10(d): institutions must conduct ongoing due diligence on the business relationship, including scrutiny of transactions throughout that relationship. Recommendation 10, paragraph 23, adds that CDD information must be kept up to date, with higher-risk categories under closer refresh. The first stale swap of the hour is already friction (3%); later swaps in the same hour are sized by USD.

The same $1,000 / $15,000 cuts apply, and the outcome stays inside allow or extra fee. The wallet already has a favourable oracle write, even if stale. A hard block on that basis would be disproportionate friction against a relationship already assessed. The 20% extra accelerates the band the same way as in A; the ceiling of this floor remains 8% so B stays internally consistent.

**C. 24-hour aggregation.** Any wallet. Dollars already recorded in the last 24 hours. While that prior total is zero or the sum stays under $15,000, C stays idle and A, B, or D decide each swap. The later swap that makes prior-24h + this swap cross $15,000 reverts (`DailyAggregationBlocked`). A first $15,000 ticket of the day is A/B/D. The hook governor retunes the 24-hour window.

Recommendation 10 says the occasional-transaction threshold applies to a single operation **or** to several operations that appear to be linked. FATF sets no numeric window for that linkage; each institution chooses one under its own risk-based approach.

The 24-hour window is a design choice, by analogy with Currency Transaction Report (CTR) aggregation under the United States Bank Secrecy Act (BSA), which adds transactions inside the same banking day to decide whether the reporting threshold was crossed. It is a documented reference, not a FATF figure, and remains governor-retunable.

FinCEN's advisory on convertible virtual currency (CVC) kiosks describes the pattern this floor is built to catch: structuring deposits under the CTR threshold across multiple operations or accounts (smurfing).

| 24-hour accumulated USD | Result |
| --- | --- |
| Under $15,000 | C stays idle |
| The swap that crosses $15,000 | REVERT |

**D. Unevaluated inbound funds.** A, B, and C miss this case: a wallet already published clean receives a P2P transfer and swaps before `updateScore`. The hook compares the current input-token balance to the last baseline and quotes the inbound amount to USD. Under $1,000 → pass; $1,000–$14,999 → 3%; $15,000 or more → 8%. D maps to allow or extra fee. On a never-written wallet the baseline is 0, so the whole current bag is inbound. A small first swap of a large new bag still pays D's band. The 50% bag share is an audit event only.

The same Rec. 10(d) and paragraph 23 ongoing-CDD duty that arms B explains why inbound funds the score has not seen produce friction rather than a hard block.

There is a further FATF warning against over-reacting. The Updated VASP Guidance, in its discussion of listings and supervision, cautions against unnecessary de-risking: wholesale refusal of customers or operations to avoid any risk exposure, at the expense of already-identified, lower-risk counterparties. A hard block on a large inbound to a wallet already published clean is that kind of over-reaction. The general proportionality principle in the Interpretive Note to Recommendation 1 requires measures to match the identified risk, not a generic suspicion.

Floor D omits the 20% pool-impact extra. Extending it to a revert would break the one rule that holds D together, and the case against blocking a legitimate inbound is independent of receiving-pool size.

**Normative reference**

| Floor | FATF source | Cite |
| --- | --- | --- |
| A, $1,000 cut | Virtual-asset-specific threshold | Updated VASP Guidance 2021, note 37 |
| A, $15,000 cut | General occasional-transaction threshold | Recommendation 10 |
| B and D, armed by a stale score | Ongoing CDD | Recommendation 10(d) and paragraph 23 |
| C, aggregation of linked operations | Linkage principle, no fixed window | Recommendation 10 |
| D, high band without a block | Risk of unnecessary de-risking | Updated VASP Guidance 2021, listings and supervision |
| Proportionality of the whole design | Governing principle of the risk-based approach | Interpretive Note to Recommendation 1 |

The inflow floor sees a pattern (new funds, then a swap). It leaves the sender unnamed. A legitimate large deposit plus an immediate swap pays the same temporary 3% or 8% until the keeper writes. That false positive is accepted and bounded to the catch-up window. N-hop decay is what attributes contamination once the write lands.

The keeper writes when the new score would change the decision tier (ALLOW / FEE_OVERRIDE / REVERT) or the 3% / 8% fee band, **or** on the 3-minute heartbeat (same score, new `updatedAt`, no agent call), **or** when the last write is at least as old as `stalenessThreshold` (5 minutes). A move from 12 to 15 is skipped if the row is still fresh. A move from 28 to 34 is written. A move from 42 to 65 is written (3% → 8%). A same-tier write after the window ages is a freshness stamp: same score, new `updatedAt`. That is the only way the clock moves. `updateScore` is still the only on-chain stamp. Floor B then fires only when the keeper is actually late (agent and tick both slower than 5 minutes), not because a stable clean wallet was skipped forever.

**Who retunes what**

| Parameter | Default | Who |
| --- | --- | --- |
| Score cuts 31 / 55 / 71 | Fixed | n/a |
| Fee percentages 3% / 8% | 300 / 800 bps | Compliance officer (48-hour delay). Proportional must stay strictly below punitive. No other numeric bound. `MAX_OVERRIDE` is out of scope for these knobs. |
| Pool base fee 0.30% | 30 bps | Fixed |
| Unknown-wallet USD floors | $1,000 / $15,000 | Compliance officer (48-hour delay). Fee floor cannot go below $1,000 (FATF VA). Revert floor must stay strictly above the fee floor. |
| Pool-impact extra | 20% | Compliance officer (48-hour delay). No numeric range. |
| Inflow share (of current USD) | 50% | Hook governor |
| Score staleness | 5 minutes (contract and local-deploy default). Institutional pools may set 120 seconds. | Hook governor |
| Keeper heartbeat (off-chain) | 3 minutes (`KEEPER_TICK_MS`). Stamps last score; leaves the agent uncalled. | API env. Not an on-chain knob. |
| Price staleness | 1 hour (flags a live round in `PriceFallbackUsed`; leaves the swap un-reverted on that flag alone). Hot cache `FX_HOT_TTL` is 30 minutes (skip Chainlink). Cache fail-closed at 24 hours. | Hook governor (1 hour knob only) |
| Per-token price feed | Official Chainlink ETH/USD (native + WETH) and USDC/USD at deploy on live chains. Anvil uses MockUsdFeed. Extra tokens unbound: skip live if `lastFx` &lt; 30 minutes; else use `lastFx` until 24 hours; else fail-closed | Hook governor |
| Trusted routers / position managers | Seeded at deploy | Hook governor |
| Floor B activity window | 1 hour | Hook governor |
| Floor C daily window | 24 hours | Hook governor |

Deploy binds official Chainlink ETH/USD and USDC/USD on live chains. The governor binds any extra pool currency via `setPriceFeed`.

**Adjustability of policy parameters**

The score cuts stay fixed (31 / 55 / 71). The fee percentages, USD floors, and pool-impact cut sit in compliance-officer-adjustable state: propose is immediate, apply is `restricted` so the 48-hour AccessManager grant delay gates confirmation. That role is distinct from the hook governor, who still administers trusted routers, price feeds, and operational windows.

The $1,000 / $15,000 cuts, the 20% pool-impact extra, the Rec. 10(d) and paragraph 23 refresh duty, the Updated VASP Guidance warning against de-risking, and the Rec. 10 linkage principle are the same sources already cited under "Why each floor exists." The bibliographic form of the VA threshold is the Updated Guidance: A Risk-Based Approach to Virtual Assets and Virtual Asset Service Providers (FATF/OECD, 2021), footnote 37. Floor C's 24-hour window remains the BSA CTR analogy and the FinCEN CVC-kiosk advisory already stated above.

Recommendation 1 requires that policies, controls, and procedures be approved by senior management. That cite is the basis for separating operational scoring, which compliance performs through the keeper, from policy-level changes to these thresholds and percentages. Policy changes require the compliance role, a 48-hour delay, and an on-chain event on both the proposal and the confirmation before taking effect. The only numeric validations are the FATF VA $1,000 floor on the fee threshold and the rule that, in each related pair, the upper value stays strictly above the lower.

**Residual risk: price oracle.** Unknown-wallet size, Floor B once armed, and Floor D depend on USD-8. If `lastFx` is younger than 30 minutes (`FX_HOT_TTL`), the swap skips Chainlink and sizes the ticket from that cache. Otherwise it reads the feed once per token and stores a usable round. A halted aggregator or an unbound feed leaves the last cached price in force (up to 24 hours, `MAX_PRICE_STALENESS`) so this ticket still sizes. Those windows can under-count USD after a sharp move, so Floor A and Floor C may look smaller than spot. After 24 hours with no usable live round the path fail-closes (`MagnitudeQuoteFailed`). Deploy binds official Chainlink ETH/USD and USDC/USD. The governor binds extra tokens and keeps `priceStalenessThreshold` at or above the feed heartbeat (that knob flags stale live rounds in `PriceFallbackUsed`; that flag alone leaves the swap un-reverted).

**Residual risk: Floor B.** If the agent is down, the 3-minute tick still stamps the last score and Floor B stays quiet. If the keeper is down entirely, or slower than `stalenessThreshold` (5 minutes), a published-clean wallet pays friction until a write lands: 3% on the first swap of the hour, then pass / 3% / 8% by swap+window USD once it has already swapped in that hour. That is intended lag, distinct from a contamination finding. Once the hour has activity, B sizes USD from `lastFx` when it is younger than 30 minutes, else from the live Chainlink round, else from `lastFx` until 24 hours. It fail-closes only when none of those are available. The freshness write (same score, new timestamp) is what stops a healthy keeper from looking late. The oracle allows 24 `updateScore`s per wallet per hour so a 5-minute stamp plus a few real tier changes fit.

**Residual risk: Floor C.** The 24-hour window is a BSA CTR analogy, not a FATF number. A venue that already identifies counterparties may widen it. A venue that still lacks that identification should treat 24 hours as a conservative default until that review is complete. A first $15,000 ticket of the day is A/B/D.

### 8.5 Walkthrough of one swap

Uniswap v4 puts every pool in one PoolManager. That single execution point is what makes hooks possible. Accounting is deferred: obligations are recorded during the lock and settled at the end.

1. **Sign.** The user signs. The transaction goes to a router. No compliance yet.
2. **Lock.** The router unlocks the PoolManager.
3. **Swap call.** Inside the lock the router calls swap. Direction and size matter for later USD quotes. Hook data is ignored as identity.
4. **Hook bits.** The pool key carries **AmlHook** (not the satellite). Permissions: before-swap, after-swap, after-swap return-delta (take the extra fee without rewriting the LP fee), before-add, after-add, after-add return-delta (never-scored or 31–70 mint takes the full 3%/8% into FeeEscrow), before-remove, after-remove, and after-remove return-delta (blocked LP exit takes principal and fees without crediting the LP).
5. **Before the swap.** PoolManager calls AmlHook. The hook `DELEGATECALL`s the satellite. The satellite resolves the end-user from a trusted router, then L1 → score → latency signals → USD (`lastFx` if younger than 30 minutes, else Chainlink once per token) → `RiskPolicy.decide`. Unknown wallet: 3% / 8% / revert by this swap. Published clean with inbound, a stale first swap of the hour (3%), or a stale score plus prior activity: pass / 3% / 8% by USD (B and D map to allow or extra fee). High score → revert. Floor C (24-hour sum crossing $15,000) → revert. Medium score → continue at the standard pool fee and remember the override. Low score, fresh write, no floor → continue at 0.30%.
6. **Pool math.** Ticks, price, output. Tokens have not moved yet.
7. **After the swap.** The hook `DELEGATECALL`s the satellite again to close the cache, update activity and the USD window, and emit the audit event. **AmlHook** (not the satellite) then `take`s the extra slice into FeeEscrow on fee-override. A failed deposit leaves the swap intact.
8. **Settle.** The router pays and withdraws, or leaves a credit in the PoolManager.
9. **Close the lock.** Any leftover obligation reverts the whole transaction.
10. **Confirm.** About twelve seconds on Ethereum, about one second on most L2s (Layer 2 networks).

AmlHook sits on two of those ten steps: 5 and 7. The satellite runs the
evaluation inside those two; settlement (`take`) stays on the hook. The rest
is a normal Uniswap v4 pool. Step 7 is where memory of the swap is written
for the next decision.

### 8.6 Tooling

Section 7 is the officer that writes the score and the Opinion file. This subsection lists **intended** production KYT sources. The UHI10 demo now screens the public OFAC SDN ETH-address dump on every COA evaluation and Opinion; a direct match is written to `SanctionRegistry`. The swap still only reads that mapping. There is no Treasury call inside `beforeSwap`. That Layer 1 path is hook functionality (`SanctionHit`), not a guided-demo wallet. Wallet A remains an exploit score 100 without a listing (`WalletBlocked`). Other vendor KYT feeds (Chainalysis, TRM, Elliptic, OpenSanctions, Etherscan, GoPlus) are unwired. Claude (or the skill interpreter when the key is off) scores from the Anvil ledger plus that live SDN screen, `SanctionRegistry`, and the git corpus (`search_regulations`). Layer 1 at execution is `SanctionRegistry`. Layer 2 is `ComplianceOracle` (3-minute keeper stamp + attestor; agent-published score and fee). USD magnitude uses Chainlink (or `MockUsdFeed` on Anvil).

#### 8.6.1 Signals

The production oracle is designed as a weighted aggregator. Each source would contribute by reliability. OFAC SDN ETH addresses are wired (COA fetch + registry writer). Chainalysis, TRM, Elliptic, Forta, EAS, and Hypernative are unwired.

| Source | Role | Type |
| --- | --- | --- |
| OFAC SDN | Official crypto-address list since 2018 | Official: live in the COA; swap reads `SanctionRegistry` |
| Chainalysis | Institutional on-chain mapping, binary sanctioned-or-not | Commercial |
| TRM / Elliptic | Comparable coverage; TRM strong in LatAm, Elliptic in Europe | Commercial |
| Forta | Distributed bots; sometimes minutes of lead time on exploits | Decentralized |
| Ethereum Attestation Service | On-chain risk attestations | Decentralized |
| Hypernative | Real-time exploit and anomaly alerts | Commercial |
| DeFiLlama Hacks DB | Public hack registry | Community |
| FinCEN / FATF advisories | Typologies the scoring must detect | Regulatory |

Civic and PureFi can buy the same feeds. The difference is combining them with a cumulative score and a three-way output.

#### 8.6.2 Layer 1 oracles

| Provider | Note |
| --- | --- |
| Chainalysis | Default for large regulated venues; KYT and Reactor |
| TRM Labs | Granular exchange and mixer coverage |
| Elliptic | Europe and bank crypto desks |
| Solidus Labs | DeFi plus market manipulation |
| Open on-chain registries | No single commercial vendor |

#### 8.6.3 Identity (ZK / zero-knowledge)

| Provider | Note |
| --- | --- |
| Polygon ID | Prove KYC without exposing the file |
| Civic | Document KYC → non-transferable Pass |
| Worldcoin | Proof of humanity (Sybil), a different job from regulatory KYC |
| Notebook / Holonym | Prove "not sanctioned" without revealing identity |

Identity sits outside the current oracle surface. The hook reads sanctions and the behavioral score. ZK (zero-knowledge) proofs sit outside that read path.

#### 8.6.4 Off-chain write path

Production: Chainlink Functions / CCIP (Cross-Chain Interoperability Protocol), or an equivalent signed job. Prototype: a server signs with a dedicated attestor key. The oracle keeper submits the transaction. The governor rotates the attestor.

The Graph can be the production reporting side. The prototype uses the API event log (`GET /events`). Evaluation is of the hook's decision, not the indexer.

#### 8.6.5 Community reports (later)

A later track: LPs with a minimum stake report on-chain behavior. One report does nothing. A threshold of independent reports, plus a challenge window and time decay, can lift a wallet into the extra-fee tier. A direct block still needs multiple validated reports plus the behavioral oracle.

The moat is the shared registry across pools. A wallet reported in ETH/USDC carries that elevation into WBTC/USDC. That flywheel needs real adoption.
