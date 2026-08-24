#!/usr/bin/env bash
export PATH="$HOME/.foundry/bin:$PATH"
curl -s -X POST http://127.0.0.1:8545 \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
echo
cd /mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook/contracts
forge script script/Deploy.sol:Deploy --list
