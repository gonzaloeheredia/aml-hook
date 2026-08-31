# AML (Anti-Money Laundering) Hook · API (application programming interface) (keeper + COA (Compliance Officer Agent))

TypeScript API. Wallets **A–D** are the in-memory guided ledger (`store.ts`): balances, hops, quotes, P2P, Restart. Those IDs never `eth_call` or send a tx. Wallet **E** is Sepolia: faucet, optional balance overlay, and `SwapObserved` logs. `/health` may still ping RPC.

**A–D (always).** `GET /wallets` reads the store (`scoreSource: "memory"`). Quotes use hop + band (`hopScore` / `decisionFromScore`). `POST /transfers` and `POST /swaps` mutate RAM. `POST /reset` is `resetStore` + in-memory oracle seed. No `seedBalances`, no `updateScore`.

**Sepolia (`ORACLE_CHAIN_ID=11155111`).** Reads [`contracts/deployments/11155111.json`](../../contracts/deployments/11155111.json) (env overrides win). Used for Wallet E faucet (`POST /demo/mint` `{ address }`), `/health`, and chain events. Requires `ORACLE_RPC_URL` for those routes. A dead RPC must not fail A–D. Public address template: [`.env.sepolia.example`](.env.sepolia.example). Pool write-up: [`docs/Sepolia.md`](../../docs/Sepolia.md). `/demo/elapse` is the A–D demo clock.

**Oracle COA:** with `ANTHROPIC_API_KEY` in `apps/api/.env`, Claude emits `finalScore`, `recommendedFeeBps`, and the Opinion (tools: `consult_skill` / `uhi10-use-case`, `search_regulations`, `screen_ofac`). For A–D that row stays in the API cache (publish to `ComplianceOracle` is skipped). On every evaluation the COA screens OFAC SDN ETH addresses; A–D skip the `SanctionRegistry` write. Tests and `OFAC_LIVE=0` skip Treasury. There are still **no** live calls to OpenSanctions, Etherscan, GoPlus, Chainalysis, or TRM. E stays unpublished unless an operator writes.

**Quotes:** A–D are TypeScript policy (same mapping as `RiskPolicy.decide`). Wallet E / live subjects use `AmlHook.previewSwap` only when a route still needs an on-chain preview.

**FEE_OVERRIDE settlement:** A–D apply the fee in the store (`applyPoolSwap`). They do not call `observeSwap` or `FeeEscrow.deposit`. A live Uniswap fill on Sepolia is Wallet E (app.uniswap.org). Escrow / vault / treasury endpoints still exist for the on-chain funds stack.

The keeper writes when the ALLOW / FEE / REVERT tier or the 3% / 8% fee band changes, **or** on a 3-minute heartbeat (same score, new `updatedAt`), **or** when the last write is at least as old as Floor B (`STALENESS_MS` = 5 minutes). That freshness stamp prevents a stable clean wallet from being classified as stale. Floor B: stale + no swap yet this hour → 3%; stale + prior activity → pass / 3% / 8% by swap+window USD (United States dollar). `updateScore` is signed by Anvil **#9** (attestor) over `attestationHash`. An empty signature is rejected.

## Frontend to API mapping

| Frontend today | API endpoint |
|---|---|
| `simWallets` / `initialSimWallets` | `GET /wallets`, `GET /wallets/:id` (A–D memory; E may overlay Sepolia) |
| `applyTransfer` | `POST /transfers` (A–D store hop + balances) |
| quote / swap | `GET /wallets/:id/quote`, `POST /swaps` (A–D `applyPoolSwap`). E uses Uniswap, not this settle |
| agent opinion | `GET /wallets/:id/compliance` (cache for A–D) |

## Run

```bash
# repo root: Anvil + Deploy + apps/api/.env.local
npm run deploy:local

cd apps/api
npm install
npm run dev
```

Default: [http://localhost:4000](http://localhost:4000)

Restart the API after every `deploy:local` so it loads `.env.local`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | `mode: "anvil"` or `"sepolia"`, `agent.score` / `agent.opinion`, `keeperTickMs`, `chain.ok` |
| `GET` | `/wallets` | All wallets + quote (A–D memory; E optional chain overlay) |
| `GET` | `/wallets/:id` | One wallet (`A`–`E`) + quote |
| `GET` | `/wallets/:id/compliance` | **Oracle opinion** for Opinion UI (user interface) |
| `GET` | `/wallets/:id/quote` | USDC→ETH quote (`?amountUsd=1000`). A–D: memory policy |
| `GET` | `/oracle` | All cached ScoreResults |
| `GET` | `/oracle/:id` | ScoreResult + opinion for one wallet |
| `POST` | `/oracle/:id/catch-up` | Publish deferred keeper score (Wallet D latency path) |
| `GET` | `/oracle/publishes` | Keeper `updateScore` trail (`txHash`) |
| `POST` | `/transfers` | P2P USDC in the store when A–D is involved. Hop contamination is memory-only |
| `POST` | `/swaps` | A–D: quote + `applyPoolSwap` + demo event. No `observeSwap` / FeeEscrow |
| `POST` | `/demo/elapse` | Advance the A–D demo clock (`{ seconds: 301 }` → Floor B) |
| `POST` | `/demo/mint` | A–D `{ walletId, token, amount }` increments the store. Faucet `{ address }` mints 1,000 MockUSDC + 1 MockWETH on Sepolia (does not write a score) |
| `POST` | `/demo/price-feed` | Bind / unbind USDC/USD (`{ bound: false }` → silent `lastFx` if quoted in the last 30 min; `PriceFallbackUsed` until 24h after that; else `MagnitudeQuoteFailed`) |
| `GET` | `/escrow` | Live FeeEscrow rows |
| `POST` | `/escrow/:id/checkpoint2` | Checkpoint 2 reads oracle/list (no keeper bool) |
| `POST` | `/escrow/:id/recover` | Recover Blocked → compliance reserve |
| `GET` | `/compensation` | Vault balance, open/closed epochs, claim leaves (`?account=`) |
| `POST` | `/compensation/accrue/:id` | Book a released FeeEscrow RiskFee row into the open epoch |
| `POST` | `/compensation/close-epoch` | Accrue + merkle over `COMPENSATION_LPS` + `closeEpoch` |
| `POST` | `/compensation/claim` | `{ epochId, account }`: keeper submits the merkle claim |
| `GET` | `/treasury` | Ledger balances + payout queue |
| `POST` | `/treasury/destinations` | Allowlist an authority address |
| `POST` | `/treasury/propose` | `{ account, amountUsdc, to, memo }` |
| `POST` | `/treasury/:id/execute` | After 48h (`/demo/elapse` on Anvil) |
| `POST` | `/treasury/:id/cancel` | Release a pending payout reserve |
| `GET` | `/transfers` | Transfer history |
| `GET` | `/events` | Hook trail (`SwapObserved` / blocked) |
| `POST` | `/reset` | `resetStore` + in-memory oracle seed A–D (no Sepolia mint / `updateScore`; E unpublished) |

### Oracle flow

The keeper publishes via signed RPC (remote procedure call).

```
P2P transfer or afterSwap / WalletBlocked
        │
        ▼
  oracle COA (skills in agents/oracle-coa)
        │
        ├─► OFAC SDN ETH screen → SanctionRegistry.setSanctioned on match
        ├─► Claude (or skill interpreter) → cache
        │
        └─► ComplianceOracle.updateScore (signed RPC, or fail)
              keeper = Anvil #0 · attestor = Anvil #9
        │
        ▼
  A–D quote / swap → memory hop + band (no ComplianceOracle write)
  opinion → GET /compliance → Opinion stage (includes live SDN result)
```

See [`.env.example`](.env.example) for required Anvil env vars and [`.env.sepolia.example`](.env.sepolia.example) for Sepolia public addresses. Put `ANTHROPIC_API_KEY` in `apps/api/.env` (gitignored) or the host panel. Do not put it in `.env.example`, `.env.sepolia.example`, or `.env.local`.

### Example: compliance opinion (oracle-backed)

```bash
curl http://localhost:4000/wallets/C/compliance
curl http://localhost:4000/oracle/B
```

### Example: contaminate then re-read opinion

```bash
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"A\",\"to\":\"B\",\"amountUsd\":10000}"

curl http://localhost:4000/oracle/B
curl http://localhost:4000/wallets/B/compliance
```

### Example: Wallet D inflow (clean C→D, no hop)

```bash
# C still clean: credits D without a hop. Inflow vs last baseline → 3%.
curl -X POST http://localhost:4000/transfers ^
  -H "Content-Type: application/json" ^
  -d "{\"from\":\"C\",\"to\":\"D\",\"amountUsd\":10000}"

curl http://localhost:4000/wallets/D/quote
# → FEE_OVERRIDE · feeBps 300 · latencyMitigation INFLOW_HEURISTIC · hopDistance null

curl -X POST http://localhost:4000/swaps ^
  -H "Content-Type: application/json" ^
  -d "{\"walletId\":\"D\",\"amountUsd\":1000}"
# → store applyPoolSwap; D stays score 0 (no hop to publish)
```

## Use-case baseline

**A** is a confirmed exploit at score 100 and is absent from the OFAC list. A pool swap hits `WalletBlocked`. P2P still contaminates B, C, and D. Do not fund E from A.

**B** and **C** both start clean (ALLOW 0.30%). **C** holds 50,000 USDC and funds E (unknown, no hop) or D (inflow).

**D** starts with 5,000 USDC and a published score 0. Receive from **A** → ~65 / 8% (1-hop). Receive from the other after it was tainted by A → ~42 / 3% (2-hop). The closer hop wins.

Clean **C → D** (or B while clean) is not a hop: ~10k → **FEE_OVERRIDE 3%** (inflow); ≥ $15,000 → **FEE_OVERRIDE 8%**.

**Wallet E** has no oracle row. Hosted: faucet `{ address }` + Uniswap. Simulator C→E is RAM only and does not fund that EOA. Floor A is this swap. Floor D is the unpublished bag. The stricter fee wins. Bag under $1,000 → 3%. $10k then $1k swap → 8% (A mid). $15k bag → 8% on a small swap (D). This swap ≥ $15,000 → `UnscoredMagnitudeBlocked`. 24h sum → `DailyAggregationBlocked`.

**1 ETH = 1,000 USDC** on Anvil only (`MockUsdFeed` at local deploy). Demo ETH is mintable `MockWETH` (18 decimals). It is not native Anvil ETH. Live Deploy binds official Chainlink ETH/USD and USDC/USD. On-chain floors are USD-8 (`1_000e8` / `15_000e8`), not native ether. `_COMPLIANCE_OFFICER` can retune those floors after a 48h confirm.

## Anvil identities + keeper

```bash
# repo root
npm run deploy:local
cd apps/api
npm run dev
```

`.env.local` (from `scripts/sync-deployment.mjs`) sets RPC, hook, oracle, FeeEscrow, fee token, `WETH_TOKEN_ADDRESS`, feeds, treasury / vault / `COMPENSATION_LPS`, `KEEPER_PRIVATE_KEY` (Anvil **#0**), and `ATTESTOR_PRIVATE_KEY` (Anvil **#9**).

| Account | Role |
|---|---|
| Anvil #0 | Admin / registry keeper / oracle keeper / hook governor / compliance officer / FeeEscrow owner |
| Anvil #1–#5 | Demo wallets A–E. Keys stay on the API |
| OFAC SDN ETH match | Hook Layer 1: COA writes `SanctionRegistry`; swap → `SanctionHit`. Not a demo wallet |
| Anvil #9 | Distinct attestor. Signs `attestationHash` |

`KEEPER_PRIVATE_KEY` must hold AccessManager role `_ORACLE_KEEPER` (role id `2`) or `updateScore` reverts with `AccessManagedUnauthorized`. `ATTESTOR_PRIVATE_KEY` must be the oracle attestor or the signature is rejected.

Check: `GET /health` → `ok` / `mode: "anvil"` or `"sepolia"` / `chain.ok`.
Trail: `GET /oracle/publishes` → `status: "submitted"` + `txHash`.

See also [`contracts/README.md`](../../contracts/README.md) for `script/Deploy.sol` env overrides (`ORACLE_KEEPER`, `HOOK_GOVERNOR`, `COMPLIANCE_OFFICER`, `ATTESTOR`, …). On Sepolia, `updateScore` is the same split: only `_ORACLE_KEEPER` submits; the attestor signs `attestationHash` including the publishing block's `timestamp`. Live role addresses: [`docs/Sepolia.md`](../../docs/Sepolia.md).
