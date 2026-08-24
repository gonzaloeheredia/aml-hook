#!/usr/bin/env bash
set -eu
export PATH="$HOME/.foundry/bin:$PATH"
cd /mnt/c/Users/gonza/Desktop/UNISWAP/aml-hook/contracts
forge test --threads 2
