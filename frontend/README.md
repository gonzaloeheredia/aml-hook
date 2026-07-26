# AML Hook · Frontend demo

Hackathon UI for **Uniswap Hook Incubator 10 (UHI10)**.  
Uniswap-styled demo that walks judges through three hardcoded compliance outcomes for an AML Hook on Uniswap v4.

> All data is mocked. Smart contracts and the Compliance Officer Agent backend will be wired later.

## What it shows

| Area | Purpose |
|---|---|
| **Swap widget** | Familiar Uniswap entry point (`Get started`) |
| **Connect modal** | Fake MetaMask → pick 1 of 3 demo addresses |
| **Case switcher** | Circles on the left of the simulator (after connect) |
| **Flow simulator** | n8n-style nodes for the hook lifecycle (draggable) |
| **Fee summary** | Pool fee, AML fee, structuring count, gas, total time |
| **Audit report** | 4 blocks: metadata, overview, detection, AI agent |

### The three demo cases

1. **Low risk** — standard fee (`ALLOW`)
2. **Medium risk / structuring** — 3x differential fee (`FEE_DIFERENCIAL`)
3. **OFAC blocked** — swap reverts (`REVERT`)

Each case ships with hardcoded scores, step latencies, gas, and a Compliance Officer Agent opinion (skills, typologies, findings, dictamen).

## Run locally

```bash
cd frontend
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Project structure

```
frontend/
├── src/
│   ├── app/
│   │   ├── layout.tsx      # Root layout, font, metadata
│   │   ├── page.tsx        # Main demo page / state orchestration
│   │   └── globals.css     # Uniswap-like theme + bokeh / gauge helpers
│   ├── components/
│   │   ├── NavBar.tsx
│   │   ├── ConnectModal.tsx
│   │   ├── SwapWidget.tsx
│   │   ├── CaseSwitcher.tsx
│   │   ├── FlowSimulator.tsx
│   │   ├── FeeSummary.tsx
│   │   └── AuditReport.tsx
│   └── data/
│       └── cases.ts        # All hardcoded demo payloads
├── public/ref/             # Visual references from the design doc
└── README.md
```

## Demo walkthrough

1. Click **Connect** / **Get started**
2. Choose **MetaMask** → pick one of the three addresses
3. Review the **Simulator** (left circles switch cases)
4. Click **Get started** again to animate the flow (green borders + spinners)
5. Scroll to the **Audit report** and the **Compliance Officer Agent** block

## Data source

Everything the UI renders comes from `src/data/cases.ts`.  
When the Solidity hook + Compliance Officer Agent are ready, replace those objects with live reads from:

- `ComplianceOracle.getRiskScore`
- on-chain structuring counters
- agent `score_wallet` / `run_dictamen` outputs

## Scripts

| Command | Description |
|---|---|
| `npm run dev` | Next.js dev server |
| `npm run build` | Production build |
| `npm run start` | Serve the production build |
| `npm run lint` | ESLint |

## Stack

- Next.js 15 (App Router)
- React 19
- TypeScript
- Tailwind CSS

## Related docs (repo root)

- `docs/AML_Hook_v3.docx` — product doc
- `docs/AML_Hook_CasoUso_Structuring.docx` — structuring use case
- `docs/Front-end visual.docx` — visual brief

---

AML Hook · Uniswap Hook Incubator, Cohort 10
