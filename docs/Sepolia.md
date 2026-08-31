# Ethereum Sepolia: live stack

Uniswap v4 pool on **chain 11155111** with the AML (Anti-Money Laundering) hook attached to the official
PoolManager. Tokens are the mintable MockUSDC / MockWETH from this repo. They are not
canonical Circle USDC / WETH. Reviewers open this pool on Sepolia (for example
app.uniswap.org) as **Wallet E**. The hosted API (`ORACLE_CHAIN_ID=11155111`) reads
[`contracts/deployments/11155111.json`](../contracts/deployments/11155111.json)
and can mint the faucet here. It does **not** settle A–D on this chain: those wallets
are the in-memory guided demo (`docs/Use_Case.md`). SDK `getDeployment` stays on 31337.

Addresses are also written by `script/Deploy.sol` to
[`contracts/deployments/11155111.json`](../contracts/deployments/11155111.json)
and by `script/CreatePool.s.sol` to
[`contracts/deployments/11155111-pool.json`](../contracts/deployments/11155111-pool.json).
Do not commit `contracts/.env`.

## Pool

| Field | Value |
| --- | --- |
| PoolManager | [`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| Hooks | [`0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7`](https://sepolia.etherscan.io/address/0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7) |
| currency0 (MockWETH, 18) | [`0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a`](https://sepolia.etherscan.io/address/0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a) |
| currency1 (MockUSDC, 6) | [`0xa95c6057B2Bf93476590D93539dC5beB53549684`](https://sepolia.etherscan.io/address/0xa95c6057B2Bf93476590D93539dC5beB53549684) |
| fee | `8388608` (`LPFeeLibrary.DYNAMIC_FEE_FLAG`) |
| tickSpacing | `60` |
| LP (liquidity provider) wallet | `0x01C67DDF409e70A03342854d9F22278A2aaf87d4` |
| Liquidity router (periphery test) | `0x0C478023803a644c94c4CE1C1e7b9A087e411B0A` |

Initialize: [`0xd3410dec…fdc2`](https://sepolia.etherscan.io/tx/0xd3410deceb110e7012803970e31abd2f63720cd9d1e52d839d5cc350c1fbfdc2).
First add: [`0xd38c46f9…02eb`](https://sepolia.etherscan.io/tx/0xd38c46f9e38725e49362ded7e00a2ffb9174b35f82d5593aa55898aecefc02eb)
(0.1 WETH + 100 USDC intended; the manager holds the price-matched slice, ~0.0406 WETH + 100 USDC).

Official PoolManager address comes from the installed Uniswap artifact
`contracts/lib/v4-periphery/broadcast/01_PoolManager.s.sol/11155111/run-latest.json`
(`returns.manager`). It does not come from memory.

## Stack

| Contract | Address |
| --- | --- |
| AmlHookSatellite | `0x6e14cf005697e20a7Dc52bea5F1AD927609d53E4` |
| AccessManager | `0x52C589cE6140F482795897D0b11852203a6403fC` |
| SanctionRegistry | `0xBf46E7dad8286FC3e487C22b27F17D734814df5d` |
| ComplianceOracle | `0xED5ED80715D886e4cE808269e69fcDFBeD22733B` |
| RiskPolicy | `0x4427FD537B0c7486fCaE7128a406FcD941723aD8` |
| FeeEscrow | [`0xB8487ea37DF8576d6219ae1C61FF72D17F445925`](https://sepolia.etherscan.io/address/0xB8487ea37DF8576d6219ae1C61FF72D17F445925) |
| LpCompensationVault | [`0x2e24716c2D99b960185E0ED85E30696EA9921974`](https://sepolia.etherscan.io/address/0x2e24716c2D99b960185E0ED85E30696EA9921974): clean RiskFee destination |
| ComplianceTreasury | [`0x6a971F7EaB0e1CA8Bd85BFD7A21a1639841f86d7`](https://sepolia.etherscan.io/address/0x6a971F7EaB0e1CA8Bd85BFD7A21a1639841f86d7): illicit recover + delayed payout |
| ComplianceTreasury (genesis, unused) | `0x0281A79ce8234C9601472118a45C343a53C06650` |
| Trusted router (Universal Router) | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| ETH/USD (United States dollar) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| USDC/USD (`TOKEN_USD_FEED` on MockUSDC) | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |

## Roles (this deploy)

`updateScore` is AccessManaged role `_ORACLE_KEEPER` (id `2`). Only the oracle
keeper may submit the tx. A distinct attestor ECDSA (Elliptic Curve Digital Signature Algorithm)-signs `attestationHash`
(must include `block.timestamp` of the publishing block).

| Role | Address |
| --- | --- |
| Deployer / admin / compliance officer / FeeEscrow owner | `0x01C67DDF409e70A03342854d9F22278A2aaf87d4` |
| `_REGISTRY_KEEPER` | `0x52BF625063E299b550aB503A9b5553F27203c225` |
| `_ORACLE_KEEPER` | `0x8132f689aB76DD5f595C7B4CC52Cab0C6e268b13` |
| `_HOOK_GOVERNOR` | `0xFeb2776Ca576e3aF775Af2DA0464be39Af13B4D6` |
| Attestor (not a manager role) | `0xc90441a6E5B087225EC6382D6815564C6beC112c` |

Obsolete hooks (do not use): `0xc1a2…cFc7` was bound to a 57-byte
`MockPoolManager`. `0xf558…CFC7` used the official manager but a misaligned
satellite storage prefix (`sanctionRegistry` read `complianceTreasury`).

## How it was deployed

From `contracts/` with `contracts/.env` loaded by Foundry:

```text
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
FEE_TOKEN=0xa95c6057B2Bf93476590D93539dC5beB53549684
WETH_TOKEN=0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a
TOKEN_USD_FEED=0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
```

```bash
forge script script/Deploy.sol:Deploy --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
forge script script/CreatePool.s.sol:CreatePool --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
```

To attach the product funds without redeploying the hook or pool (FeeEscrow owner):

```bash
FEE_ESCROW=0xB8487ea37DF8576d6219ae1C61FF72D17F445925 \
AML_HOOK=0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7 \
SANCTION_REGISTRY=0xBf46E7dad8286FC3e487C22b27F17D734814df5d \
COMPLIANCE_ORACLE=0xED5ED80715D886e4cE808269e69fcDFBeD22733B \
WETH_TOKEN=0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a \
forge script script/WireFunds.s.sol:WireFunds --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
```

That writes `deployments/11155111-funds.json` and retargets FeeEscrow destinations.

`AmlHook` + `AmlHookSatellite` stay under the 24 576-byte EIP-170 (Ethereum Improvement Proposal 170) cap
(~22.9 kB each). Evaluation runs via `DELEGATECALL`. Inheritance on `AmlHook`
must list Activity / Governance **before** Settlement so the satellite prefix
(`AccessManaged` → `sanctionRegistry` at slot 1) matches. Test:
`UnitAmlHookStorageLayoutTest`.

`UnitDeployTest` cases that expect a fresh MockUSDC / MockWETH / unbound fee
feed fail if those three env vars are set (Foundry loads `.env`). Unset them
for a clean `forge test`. They are not required for the Sepolia pool.

## First liquidity add

`PoolModifyLiquidityTest` is **not** a trusted router. The hook scores that
contract as the LP subject. A never-scored first mint on an empty pool is 100%
impact → Floor A/D punitive 8% → `PoolManager.take` of the fee while the
manager still holds 0 of the new token → revert.

Before `CreatePool`, `_ORACLE_KEEPER` published score **10** (band 0–30,
`updatedAt != 0`) for `0x0C4780…1B0A`
([`0xf3eef929…a2ea`](https://sepolia.etherscan.io/tx/0xf3eef9293724694e141adf3074b5e9c86a4f48ff1f0d3f1a6ff445232299a2ea)).
A published 0–30 LP pays 0 extra even if the row is later stale.

Any new address that swaps or mints on this pool without an oracle row hits
Floor A/C/D (use-case Wallet E). Swaps under $1,000 take 3%. Swaps of $1,000–$14,999
take 8% (or revert if the ticket is more than 20% of pool liquidity). Swaps ≥ $15,000
revert. That is the designed never-scored path. The demo faucet (`POST /demo/mint` with `{ address }`) only mints 1,000 MockUSDC + 1 MockWETH. It is not in the MetaMask panel. It
does not call `updateScore`. Simulator A–D transfers do not move these tokens.
Unless `_ORACLE_KEEPER` later publishes a clean
row for that EOA (externally owned account), app.uniswap.org will treat the wallet as never-scored: elevated
fee or revert by size. See [`Use_Case.md`](Use_Case.md) §
environments.

After `_ORACLE_KEEPER` publishes a score for that EOA, Floors A/C no longer
treat it as never-scored. **Floor D** applies on a later inbound (mint,
then swap) the same way Steps 8–9 treat Wallet D. **Floor B** applies
if the row goes stale: five real minutes with no `updateScore`. The swap-card
**Advance 5 min** button and `POST /demo/elapse` move the A–D demo clock only.
A healthy 3-minute keeper tick stamps `updatedAt` and keeps Floor B quiet. **Hop
scoring** from Wallet A cannot be shown here: A–D hops live in API memory, not
on this EOA. An administrative score unlocks Floor B/D. It does not create
a hop.

## What is not a live Uniswap fill

`@aml-hook/sdk` `getDeployment` and `sync-deployment.mjs` stay on Anvil
`31337`. The API does **not** go through the SDK: it reads this JSON (JavaScript Object Notation) (or
env overrides) when `ORACLE_CHAIN_ID=11155111`. See
[`apps/api/.env.sepolia.example`](../apps/api/.env.sepolia.example) for
public addresses. RPC (remote procedure call) and keys stay in the host panel.

Running `npm run deploy:local` is on MockPoolManager + MockUsdFeed,
not this pool. The Next.js A–D path is the in-memory store (`POST /swaps`).
Wallet E leaves the simulator: faucet + app.uniswap.org against this
PoolManager. `/demo/elapse` is the A–D demo clock.
