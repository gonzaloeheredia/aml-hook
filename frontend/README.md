# AML Hook · Frontend demo

Hackathon UI for **Uniswap Hook Incubator 10 (UHI10)**.  
Uniswap-styled demo of the AML Hook use case: **exploit cash-out detection**, **N-hop decay**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**.

> All data is mocked. Smart contracts and the Compliance Officer Agent backend will be wired later.  
> Scores and sanctions checks are **simulated** from the N-hop ledger — no live OpenSanctions / Etherscan / GoPlus (or OFAC) API calls.

## What it shows

| Area | Purpose |
|---|---|
| **Swap widget** | Familiar Uniswap entry point (`Get started`) |
| **Connect modal** | Fake MetaMask → pick Wallet A / B / C |
| **MetaMask panel** | Right-slide sheet to simulate P2P transfers (A→B→C) |
| **Case switcher** | Circles for wallets A / B / C |
| **Flow simulator** | n8n-style nodes for the hook lifecycle |
| **Fee summary** | Pool fee, lpFeeOverride, gas, total time |
| **Audit report** | Metadata, overview, detection, agent, on-chain score event |

### The three use-case wallets

1. **Wallet A (exploit)** — score 100 · `REVERT`
2. **Wallet B (clean)** — same rules as C: A→B ≈ 65 / 8%; tainted C→B ≈ 42 / 3%
3. **Wallet C (clean)** — same rules as B: A→C ≈ 65 / 8%; tainted B→C ≈ 42 / 3%

N-hop formula: `derived_score = origin_score × (0.65 ^ hops) × exposed_proportion`  
Closer hop wins if a wallet is contaminated more than once.

## Run locally

```bash
cd frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Demo walkthrough

1. Connect **Wallet C** → swap → ALLOW 0.30% (baseline)
2. Connect **Wallet A** → swap → REVERT
3. Open **MetaMask Simulator** → Send USDC **A→B**, then **B→C**
4. Swap with **B** → FEE_OVERRIDE 8%; with **C** → FEE_OVERRIDE 3%
5. Review **AML analysis** + on-chain event trail

## Data source

Hardcoded payloads live in `src/data/cases.ts` and live hop state in `src/lib/hopScoring.ts`.  
Later wire to:

- `ComplianceOracle` / keeper score writes
- on-chain SwapObserved / ScoreUpdated / WalletBlocked events
- agent regulatory-report outputs

## Related docs (repo root)

- `docs/Whitepaper.txt`
- `docs/AML-Hook_Use_of_Case.txt`
