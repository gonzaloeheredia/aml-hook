#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
ROOT="/mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook"
RPC="http://127.0.0.1:8545"
ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

if ! command -v forge >/dev/null || ! command -v anvil >/dev/null; then
  echo "Foundry (forge/anvil) not found in WSL PATH"
  exit 1
fi

bash "$ROOT/scripts/ensure-anvil-wsl.sh"

echo "Deploying AML stack …"
cd "$ROOT/contracts"
mkdir -p deployments
forge script script/Deploy.sol:Deploy \
  --rpc-url "$RPC" \
  --broadcast \
  --private-key "$ANVIL_KEY"

cd "$ROOT"
if command -v node >/dev/null 2>&1; then
  node scripts/sync-deployment.mjs
elif command -v node.exe >/dev/null 2>&1; then
  node.exe scripts/sync-deployment.mjs
else
  echo "Deploy OK. Run on Windows: node scripts/sync-deployment.mjs"
fi
echo "Done. Restart apps/api to pick up .env.local"
