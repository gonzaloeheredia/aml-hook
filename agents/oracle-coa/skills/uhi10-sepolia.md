---
name: uhi10-sepolia
description: "Live Ethereum Sepolia (11155111) instantiation of the AML Hook use case. Consult when the subject is not an in-memory A–D demo wallet, when chainId is 11155111, or when asked about the official PoolManager pool, the untrusted liquidity router, satellite storage, or who may call updateScore. Do not copy A–D hops onto Sepolia addresses."
---

# Sepolia live pool: COA (Compliance Officer Agent) constraints

Canonical addresses: `docs/Whitepaper.md` (Stack) and
`contracts/deployments/11155111.json`. This skill states operational
constraints. It does not replace `uhi10-use-case` (A–E math still applies).

When `ORACLE_CHAIN_ID=11155111`, this API can mint the faucet and (if asked)
the keeper may submit `updateScore`. A–D quotes and swaps stay in memory.
Wallet E is a PoolManager fill (app.uniswap.org), not `previewSwap`. Do not
copy A–D hops onto Sepolia EOAs.

---

## 1. Same use case, different subjects

| Use-case role | On Sepolia |
|---|---|
| Wallet **E** | Any EOA (or untrusted caller) with `updatedAt == 0` on `ComplianceOracle` `0xED5ED80715D886e4cE808269e69fcDFBeD22733B` |
| Wallet **A** | Only if you have a confirmed exploit fact on **that** address. Memory wallet A is not this pool’s LP |
| Listed SDN (Specially Designated Nationals) | Live OFAC (Office of Foreign Assets Control) SDN exact-address match → `SanctionRegistry` `0xBf46E7dad8286FC3e487C22b27F17D734814df5d` → hook `SanctionHit`. Not a use-case wallet. Do not invent hops from a listed address |
| B / C / D hops | Only after observed P2P / facts on **these** Sepolia addresses. Do not import the A–D memory ledger |

A fresh EOA that opens the pool on app.uniswap.org is Wallet E:
Floor A/C/D. **Do not auto-publish** a score for that address.

---

## 2. Who the hook scored on the first mint

The LP EOA `0x01C67DDF409e70A03342854d9F22278A2aaf87d4` is **not** the
liquidity subject. Uniswap `PoolModifyLiquidityTest`
`0x0C478023803a644c94c4CE1C1e7b9A087e411B0A` is untrusted, so the hook
treats **that router** as `msg.sender`.

That router had no oracle row. A never-scored add on an **empty** pool is
~100% impact → Floor A mid (8%) `take`. The manager held zero, so the add
reverted. The operator then published score **10** (band 0–30 / ALLOW) for
the router so the seed could land (tx
`0xf3eef9293724694e141adf3074b5e9c86a4f48ff1f0d3f1a6ff445232299a2ea`).
CreatePool then succeeded
(`0xd38c46f9e38725e49362ded7e00a2ffb9174b35f82d5593aa55898aecefc02eb`).

**Treatment of that write**

- It is an **operator seed exception** (use-case §5 LP), not a finding that
  the test router is a clean trader or an attributed originator.
- Do not hop-contaminate other addresses from that score 10.
- Do not describe the LP EOA as published-clean because of it.
- If asked to score the same router again, keep 0–30 unless new facts appear.
  Do not raise it to mid-band because it is a contract.

Trusted swap router on this deploy (not the subject): Universal Router
`0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`.

---

## 3. Who may publish

`ComplianceOracle.updateScore` is AccessManaged `_ORACLE_KEEPER` (id 2):
`0x1dC8D5e32566FAbE56EB0CC7A5D0f80671Ab872D`.

A distinct attestor (`0x6FC381CACa9151DE11696f3ef867f76A8183e44A`) ECDSA
(Elliptic Curve Digital Signature Algorithm)-signs `attestationHash`. The
hash **must** include `block.timestamp` of the publishing block. A signature
over a guessed or previous timestamp reverts.

You draft the score. You do not submit the tx. You do not sign as attestor
from this runtime.

---

## 4. Infrastructure: never the subject

| Contract | Address | Role |
|---|---|---|
| Official PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | Uniswap v4 singleton |
| AmlHook | `0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7` | CREATE2 flags; DELEGATECALL into satellite |
| AmlHookSatellite | `0x6e14cf005697e20a7Dc52bea5F1AD927609d53E4` | Logic; storage prefix is the hook’s |
| MockWETH / MockUSDC | `0x51f63B…` / `0xa95c60…` | Demo tokens, not canonical WETH/USDC |
| RiskPolicy / FeeEscrow / treasury | see `docs/Whitepaper.md` (Stack) | Policy and escrow |

Obsolete hooks (do not analyze as the live pool): `0xc1a2…cFc7` (immutable
MockPoolManager) and `0xf558…CFC7` (official PM, **misaligned** satellite
storage: hook inherited Settlement before Activity, so `sanctionRegistry`
read `complianceTreasury` and `isSanctioned` reverted). Current hook order is
Activity → Governance → Settlement. Storage layout is not a scoring fact.

FX (foreign exchange): ETH/USD `0x694AA1769357215DE4FAC081bf1f309aDC325306`,
USDC/USD `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E`.

---

## 5. Checklist

1. Never-written Sepolia address → Wallet E. Do not publish unless the
   operator explicitly requests a seed write (0–30) for an untrusted LP
   caller on an empty or near-empty pool.
2. Do not copy in-memory A–D scores, hops, or P2P onto Sepolia.
3. Do not treat a listed SDN address as a hop source. Do not treat the score-10 liquidity
   router as hop 0 exploit.
4. Subject = hook-resolved sender (§1.3 of the system prompt).
5. Opinion sources: Etherscan / oracle / registry. Never this filename.
