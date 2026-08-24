#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
SRC="/mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook/contracts"
DST="$HOME/aml-hook-forge/contracts"

echo "=== forge $(forge --version | head -n1) ==="
mkdir -p "$(dirname "$DST")"
if [[ ! -f "$DST/foundry.toml" ]]; then
  echo "Copying contracts to $DST (WSL filesystem)..."
  cp -a "$SRC" "$DST"
fi
# Refresh only project sources/tests so local edits are used
rm -rf "$DST/src" "$DST/test" "$DST/script"
cp -a "$SRC/src" "$SRC/test" "$SRC/script" "$DST/"
cp -a "$SRC/foundry.toml" "$DST/foundry.toml"

cd "$DST"
echo "=== forge test --threads 2 --summary ==="
forge test --threads 2 --summary
