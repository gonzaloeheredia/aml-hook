/**
 * Headless demo-flow script (not Foundry / unit tests: see contracts/test for those).
 * Exercises the same HTTP API the frontend uses. No browser / no UI.
 *
 * MOCK: pool swaps & MetaMask P2P are simulated via POST /swaps and /transfers.
 * With deploy:local + API .env.local, keeper publishes REAL updateScore txs on Anvil.
 *
 * Risk rule (important):
 * - Pool swaps NEVER raise behavioral score. Clean B/C stay green after 2–3 swaps.
 * - Score / color / fee change ONLY via MetaMask P2P hops from the exploit graph:
 *   - A → B (or A → C) → hop 1 · score ~65 · fee 8%
 *   - Second hop via tainted peer (B → C or C → B) → hop 2 · score ~42 · fee 3%
 *   - Transfers involving A after A→B keep the closer hop on B (still hop 1)
 *
 * Scenario:
 * 1. C swaps twice · still score 0 / ALLOW 0.30%
 * 2. B swaps twice · still score 0 / ALLOW 0.30%
 * 3. A tries to swap → WalletBlocked (score 100, not OFAC-listed)
 * 4. MetaMask A → B (hop 1 on B), then B → C (hop 2 on C)
 * 5. B Uniswap swap → FEE_OVERRIDE 8%
 * 6. C Uniswap swap → FEE_OVERRIDE 3% (fees differentiated by hop)
 *
 * Prerequisites: backend running at API_BASE (default http://localhost:4000)
 *
 *   cd apps/api && npm run dev
 *   node test/flow-uniswap-metamask.mjs
 */

const API_BASE = (process.env.API_BASE || "http://localhost:4000").replace(
  /\/$/,
  "",
);

let passed = 0;
let failed = 0;

/**
 * Thin JSON client mirroring frontend `src/lib/api.ts`.
 */
async function api(path, init = {}) {
  const res = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...init.headers,
    },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(data.error || `HTTP ${res.status} ${path}`);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

/**
 * Assert helper: logs ✓ / ✗ and counts failures.
 */
function assert(label, condition, detail = "") {
  if (condition) {
    passed += 1;
    console.log(`  ✓ ${label}${detail ? `: ${detail}` : ""}`);
  } else {
    failed += 1;
    console.error(`  ✗ ${label}${detail ? `: ${detail}` : ""}`);
  }
}

function postSwap(walletId, amountUsd = 1000) {
  return api("/swaps", {
    method: "POST",
    body: JSON.stringify({ walletId, amountUsd }),
  });
}

function postTransfer(from, to, amountUsd) {
  return api("/transfers", {
    method: "POST",
    body: JSON.stringify({ from, to, amountUsd }),
  });
}

async function main() {
  console.log(`\nAML Hook · headless flow test`);
  console.log(`API: ${API_BASE}\n`);

  const health = await api("/health");
  assert("backend health", health.ok === true, health.mode);

  await api("/reset", { method: "POST", body: "{}" });
  assert("ledger reset", true);

  // ── 1. C swaps twice while clean: still no score ───────────────────
  console.log("\n1) Wallet C · two Uniswap swaps (clean: swaps ≠ risk)");
  await postSwap("C", 1000);
  const swapC2clean = await postSwap("C", 1000);
  const cAfterSwaps = await api("/wallets/C/compliance");
  assert("C settled", swapC2clean.settled === true);
  assert(
    "C still score 0 after 2 swaps",
    cAfterSwaps.score === 0 && cAfterSwaps.hopDistance == null,
    `score=${cAfterSwaps.score} hop=${cAfterSwaps.hopDistance}`,
  );
  assert(
    "C still ALLOW 0.30%",
    cAfterSwaps.hookOutput === "ALLOW" && cAfterSwaps.appliedFeeBps === 30,
    `out=${cAfterSwaps.hookOutput} fee=${cAfterSwaps.feePercent}%`,
  );

  // ── 2. B swaps twice while clean: still no score ───────────────────
  console.log("\n2) Wallet B · two Uniswap swaps (clean: swaps ≠ risk)");
  await postSwap("B", 1000);
  const swapB2clean = await postSwap("B", 1000);
  const bAfterSwaps = await api("/wallets/B/compliance");
  assert("B settled", swapB2clean.settled === true);
  assert(
    "B still score 0 after 2 swaps",
    bAfterSwaps.score === 0 && bAfterSwaps.hopDistance == null,
    `score=${bAfterSwaps.score} hop=${bAfterSwaps.hopDistance}`,
  );
  assert(
    "B still ALLOW 0.30%",
    bAfterSwaps.hookOutput === "ALLOW" && bAfterSwaps.appliedFeeBps === 30,
    `out=${bAfterSwaps.hookOutput} fee=${bAfterSwaps.feePercent}%`,
  );

  // ── 3. A blocked ────────────────────────────────────────────────────
  console.log("\n3) Wallet A · Uniswap swap (score 100 → WalletBlocked)");
  const swapA = await postSwap("A", 1000);
  assert("A not settled", swapA.settled === false);
  assert(
    "A WalletBlocked",
    swapA.quote?.hookOutput === "REVERT" &&
      swapA.quote?.revertReason === "WalletBlocked",
    `out=${swapA.quote?.hookOutput} reason=${swapA.quote?.revertReason} score=${swapA.quote?.score}`,
  );

  // ── 4. MetaMask hops: A→B (hop 1), B→C (hop 2) ─────────────────────
  console.log("\n4) MetaMask · A → B (hop 1), then B → C (hop 2)");
  const t1 = await postTransfer("A", "B", 10_000);
  const bHop1 = t1.wallets.find((w) => w.id === "B");
  assert(
    "A→B ⇒ B hop 1 · score 65",
    bHop1?.score === 65,
    `B score=${bHop1?.score}`,
  );

  // Optional B→A does not deepen B past hop 1 (closer hop wins)
  await postTransfer("B", "A", 1_000);
  const bAfterBA = await api("/wallets/B/compliance");
  assert(
    "B→A keeps B at hop 1 (not hop 2)",
    bAfterBA.hopDistance === 1 && bAfterBA.score === 65,
    `hop=${bAfterBA.hopDistance} score=${bAfterBA.score}`,
  );

  const t2 = await postTransfer("B", "C", 5_000);
  const cHop2 = t2.wallets.find((w) => w.id === "C");
  assert(
    "B→C ⇒ C hop 2 · score 42",
    cHop2?.score === 42,
    `C score=${cHop2?.score}`,
  );

  // ── 5–6. Differentiated fees by hop, not by swap count ──────────────
  console.log("\n5) Wallet B · Uniswap swap (1-hop → 8%)");
  const swapB = await postSwap("B", 1000);
  assert("B fee-override settled", swapB.settled === true);
  assert(
    "B FEE_OVERRIDE 8%",
    swapB.quote?.hookOutput === "FEE_OVERRIDE" && swapB.quote?.feeBps === 800,
    `out=${swapB.quote?.hookOutput} fee=${swapB.quote?.feePercent}% score=${swapB.quote?.score}`,
  );

  console.log("\n6) Wallet C · Uniswap swap (2-hop → 3%)");
  const swapC = await postSwap("C", 1000);
  assert("C fee-override settled", swapC.settled === true);
  assert(
    "C FEE_OVERRIDE 3%",
    swapC.quote?.hookOutput === "FEE_OVERRIDE" && swapC.quote?.feeBps === 300,
    `out=${swapC.quote?.hookOutput} fee=${swapC.quote?.feePercent}% score=${swapC.quote?.score}`,
  );
  assert(
    "B and C fees differ by hop (8% vs 3%)",
    swapB.quote?.feeBps !== swapC.quote?.feeBps,
    `B=${swapB.quote?.feePercent}% vs C=${swapC.quote?.feePercent}%`,
  );

  console.log("\n────────────────────────────────────");
  console.log(`Result: ${passed} passed, ${failed} failed`);
  if (failed > 0) {
    process.exitCode = 1;
    console.log("FAILED\n");
  } else {
    console.log("OK: risk is hop-based; swaps alone never score\n");
  }
}

main().catch((err) => {
  console.error("\nFatal:", err.message || err);
  console.error("\nIs the API up?  cd apps/api && npm run dev\n");
  process.exitCode = 1;
});
