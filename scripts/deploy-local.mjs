/**
 * Start Anvil (if needed), deploy AML stack, sync SDK + API env.
 *
 * Usage (from repo root, WSL or Git Bash with forge/anvil on PATH):
 *   node scripts/deploy-local.mjs
 *
 * Or manually:
 *   anvil
 *   cd contracts && FOUNDRY_PROFILE=deploy forge script script/Deploy.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
 *   node scripts/sync-deployment.mjs
 */

import { spawn, execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const contracts = join(root, "contracts");
const rpc = "http://127.0.0.1:8545";
const anvilKey =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

function forgeBin() {
  try {
    execSync("forge --version", { stdio: "ignore" });
    return "forge";
  } catch {
    // WSL foundry default
    return null;
  }
}

async function rpcUp() {
  try {
    const res = await fetch(rpc, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function main() {
  // On Windows without native Foundry, delegate to WSL script (anvil + forge + sync).
  if (!forgeBin() && process.platform === "win32") {
    console.log("No native forge — using WSL Foundry (scripts/deploy-local-wsl.sh) …");
    execSync("wsl -e bash scripts/deploy-local-wsl.sh", {
      cwd: root,
      stdio: "inherit",
      shell: true,
    });
    return;
  }

  if (!(await rpcUp())) {
    console.log("Starting Anvil on :8545 …");
    const anvilProc = spawn("anvil", ["--host", "127.0.0.1", "--port", "8545"], {
      stdio: "ignore",
      detached: true,
      shell: true,
    });
    anvilProc.unref();
    for (let i = 0; i < 40; i++) {
      await new Promise((r) => setTimeout(r, 250));
      if (await rpcUp()) break;
    }
    if (!(await rpcUp())) {
      console.error("Anvil did not start. Install Foundry and run `anvil` manually.");
      process.exit(1);
    }
  } else {
    console.log("Anvil already running.");
  }

  console.log("Deploying AML stack …");
  execSync(
    `forge script script/Deploy.sol:Deploy --rpc-url ${rpc} --broadcast --private-key ${anvilKey}`,
    { cwd: contracts, stdio: "inherit", shell: true, env: { ...process.env, FOUNDRY_PROFILE: "deploy" } },
  );

  if (!existsSync(join(contracts, "deployments/31337.json"))) {
    console.error("Deploy finished but deployments/31337.json missing.");
    process.exit(1);
  }

  execSync("node scripts/sync-deployment.mjs", { cwd: root, stdio: "inherit" });
  console.log("\nDone. Restart apps/api to pick up .env.local (SCORE_SOURCE=onchain).");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
