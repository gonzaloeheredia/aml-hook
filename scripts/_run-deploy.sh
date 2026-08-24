#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

python3 - <<'PY'
import urllib.request
req = urllib.request.Request(
    "http://127.0.0.1:8545",
    data=b'{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}',
    headers={"content-type": "application/json"},
)
print(urllib.request.urlopen(req, timeout=3).read().decode())
PY

cd /mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook/contracts
forge script script/Deploy.sol --tc Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

cd /mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook
node scripts/sync-deployment.mjs
echo DONE
