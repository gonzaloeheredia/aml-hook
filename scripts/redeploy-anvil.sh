#!/usr/bin/env bash
set -eu
export PATH="$HOME/.foundry/bin:$PATH"
ROOT="/mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook"
RPC="http://127.0.0.1:8545"
ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

sed -i 's/\r$//' "$ROOT/scripts/"*.sh 2>/dev/null || true
bash "$ROOT/scripts/ensure-anvil-wsl.sh"

mkdir -p "$ROOT/contracts/deployments"
cd "$ROOT/contracts"
forge script script/DeployAmlStack.s.sol:DeployAmlStack \
  --rpc-url "$RPC" \
  --broadcast \
  --private-key "$ANVIL_KEY"

echo "Broadcast OK — sync from Windows: node scripts/sync-deployment.mjs"
