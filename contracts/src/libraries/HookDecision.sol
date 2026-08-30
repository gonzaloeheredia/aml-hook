// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Ternary AML Hook output (whitepaper §3.3): ALLOW, FEE_OVERRIDE, or REVERT.
///
/// @dev Binary allowlists only answer "in or out". AML Hook answers three ways:
///
///        ALLOW         Score 0–30   → swap proceeds at the pool's standard fee (e.g. 0.30%).
///                                      Confirmed-clean or low residual risk after COA N-hop decay.
///
///        FEE_OVERRIDE  Score 31–70  → swap proceeds at the pool's standard fee;
///                                      the risk differential is taken in afterSwap into
///                                      FeeEscrow (48h COA path). This is Output 2 / EDD
///                                      economic friction without a hard block. Also used when
///                                      §3.8 latency floors elevate a would-be ALLOW
///                                      (Wallet D / stale / inflow).
///
///        REVERT        Score 71–100 → unconditional block (exploit source, OFAC-grade, or
///                      (+ L1 hit)     direct sanctioned link). Never-scored magnitude at/above
///                                      the hook's revert floor also REVERTs. No fee path.
///                                      SanctionRegistry hits revert before the score is read.
///
///      FeeEscrow (§3.7) only applies to the differential fee from FEE_OVERRIDE settlements.
enum HookDecision {
    ALLOW,
    FEE_OVERRIDE,
    REVERT
}
