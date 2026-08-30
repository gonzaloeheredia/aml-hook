#!/usr/bin/env bash
# Start Anvil in WSL bound to 0.0.0.0 so Windows Node can reach :8545.
# Must survive the end of the `wsl -e` session (setsid + nohup).
set -eu
export PATH="$HOME/.foundry/bin:$PATH"
RPC="http://127.0.0.1:8545"

if curl -s -X POST "$RPC" -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
  echo "Anvil already up"
  exit 0
fi

fuser -k 8545/tcp >/dev/null 2>&1 || true
sleep 0.3
setsid nohup anvil --host 0.0.0.0 --port 8545 >/tmp/anvil-aml.log 2>&1 < /dev/null &
sleep 0.5

for i in $(seq 1 40); do
  sleep 0.25
  if curl -s -X POST "$RPC" -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
    echo "Anvil started (0.0.0.0:8545, detached)"
    exit 0
  fi
done
echo "Failed to start Anvil: see /tmp/anvil-aml.log"
exit 1
