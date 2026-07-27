# AML Hook · Frontend demo

Hackathon UI for **Uniswap Hook Incubator 10 (UHI10)**.  
Uniswap-styled demo of the AML Hook use case: **exploit cash-out detection**, **N-hop decay**, and ternary **ALLOW / FEE_OVERRIDE / REVERT**.

> All data is mocked. Smart contracts and the Compliance Officer Agent backend will be wired later.

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

1. **Wallet C (clean)** — score 0 · `ALLOW` · fee 0.30%
2. **Wallet B (1-hop)** — score 65 · `FEE_OVERRIDE` · fee 8%
3. **Wallet A (exploit)** — score 100 · `REVERT`

N-hop formula: `derived_score = origin_score × (0.65 ^ hops) × exposed_proportion`  
(After B→C contamination, C moves to score ≈ 42 · fee 3%.)

## Run locally

```bash
cd frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Demo walkthrough

1. Open **MetaMask** (navbar right) → Send USDC A→B, then B→C
2. **Use in Uniswap** on the account you want to test
3. Or **Connect** → pick A / B / C directly
4. **Get started** animates beforeSwap → decision → result
5. Review **Audit** + on-chain score event trail

## Data source

Hardcoded payloads live in `src/data/cases.ts` and live hop state in `src/lib/hopScoring.ts`.  
Later wire to:

- `ComplianceOracle` / keeper score writes
- on-chain SwapObserved / ScoreUpdated / WalletBlocked events
- agent regulatory-report outputs

## Related docs (repo root)

- `docs/Whitepaper.pdf`
- `docs/AML-Hook Use of Case.pdf`
