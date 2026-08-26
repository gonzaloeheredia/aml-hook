// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGnosisSafeOwners} from "../interfaces/external/IGnosisSafeOwners.sol";
import {IMsgSender} from "../interfaces/external/IMsgSender.sol";
import {ISanctionRegistry} from "../interfaces/registries/ISanctionRegistry.sol";

/// @notice Owner-sanction aggregation rule for multisig wallets.
///         `ALL_CLEAN` reverts if any owner is sanctioned; `ANY_CLEAN` reverts only if all are.
enum MultisigAggregation {
    ALL_CLEAN,
    ANY_CLEAN
}

/// @notice Supported multisig contract types for owner enumeration.
enum MultisigType {
    NONE,          // not a multisig (used as the revoke sentinel)
    GNOSIS_SAFE    // Gnosis Safe — owners read via `getOwners()`
}

/// @notice Registry entry for a multisig account eligible to swap through the hook.
struct TrustedMultisig {
    bool trusted;     // false when the entry has been revoked
    MultisigType kind; // contract type (NONE when not trusted)
}

/// @title WalletSubject — compliance subject resolution (whitepaper §3.5)
/// @notice Resolves the true swap originator from a trusted router, with optional Gnosis Safe owner screening.
library WalletSubject {
    /// @notice Router is not in the trusted set, or subject resolution returned `address(0)`.
    error MissingSwapSubject();
    /// @notice Trusted router's `msgSender()` call reverted or returned `address(0)`.
    error TrustedRouterSubjectFailed(address router);
    /// @notice Subject wallet (or one of its Safe owners) is on the sanctions list.
    error SanctionHit(address wallet);

    /// @notice Resolve the compliance subject for a swap routed through `router`.
    /// @dev Resolution order:
    ///      1. Require `router` to be trusted.
    ///      2. Call `router.msgSender()` to get the underlying EOA or contract.
    ///      3. If the result is a contract, require it to be a registered multisig and screen its owners.
    /// @param router           The Uniswap v4 router that initiated the swap.
    /// @param trustedRouters   Registry of approved router intermediaries.
    /// @param trustedMultisigs Registry of approved multisig contracts with their type.
    /// @param sanctionRegistry Layer 1 sanctions list used to screen owners.
    /// @param aggregation      Owner-sanction aggregation policy (ALL_CLEAN / ANY_CLEAN).
    /// @return wallet          Resolved compliance subject (EOA or multisig contract).
    function resolve(
        address router,
        mapping(address => bool) storage trustedRouters,
        mapping(address => TrustedMultisig) storage trustedMultisigs,
        ISanctionRegistry sanctionRegistry,
        MultisigAggregation aggregation
    ) internal view returns (address wallet) {
        if (!trustedRouters[router]) revert MissingSwapSubject();

        try IMsgSender(router).msgSender() returns (address subject) {
            wallet = subject;
        } catch {
            revert TrustedRouterSubjectFailed(router);
        }
        if (wallet == address(0)) revert TrustedRouterSubjectFailed(router);
        if (wallet.code.length == 0) return wallet;

        TrustedMultisig memory ms = trustedMultisigs[wallet];
        if (!ms.trusted) revert MissingSwapSubject();
        requireOwnersClean(wallet, ms.kind, sanctionRegistry, aggregation);
    }

    /// @notice Screen the owners of a multisig `wallet` against the sanctions list.
    /// @dev For `ALL_CLEAN`: reverts on the first sanctioned owner.
    ///      For `ANY_CLEAN`: reverts only when every owner is sanctioned.
    ///      Currently only `GNOSIS_SAFE` kind is supported; other kinds revert.
    /// @param wallet       Multisig contract whose owners to screen.
    /// @param kind         Multisig type (must be GNOSIS_SAFE).
    /// @param sanctionRegistry Layer 1 sanctions list.
    /// @param aggregation  Aggregation policy applied to the owner set.
    function requireOwnersClean(
        address wallet,
        MultisigType kind,
        ISanctionRegistry sanctionRegistry,
        MultisigAggregation aggregation
    ) internal view {
        address[] memory owners;
        if (kind == MultisigType.GNOSIS_SAFE) {
            try IGnosisSafeOwners(wallet).getOwners() returns (address[] memory ownerList) {
                owners = ownerList;
            } catch {
                revert MissingSwapSubject();
            }
        } else {
            revert MissingSwapSubject();
        }
        if (owners.length == 0) revert MissingSwapSubject();

        bool anyOwnerClean;
        address firstSanctionedOwner;
        for (uint256 i; i < owners.length; ++i) {
            if (!sanctionRegistry.isSanctioned(owners[i])) {
                anyOwnerClean = true;
            } else {
                if (firstSanctionedOwner == address(0)) firstSanctionedOwner = owners[i];
                if (aggregation == MultisigAggregation.ALL_CLEAN) revert SanctionHit(owners[i]);
            }
        }
        if (aggregation == MultisigAggregation.ANY_CLEAN && !anyOwnerClean) {
            revert SanctionHit(firstSanctionedOwner);
        }
    }

    /// @notice Resolve the LP subject. A trusted router reports `msgSender()`; a direct caller is the LP.
    /// @dev Does not require a trusted router (unlike swaps). Does not revert on a list hit — the
    ///      caller decides add-revert vs remove-seize. A trusted router that fails `msgSender()`
    ///      still reverts. Hook data is never read.
    function resolveLp(
        address sender,
        mapping(address => bool) storage trustedRouters,
        mapping(address => TrustedMultisig) storage,
        ISanctionRegistry,
        MultisigAggregation
    ) internal view returns (address wallet, bool viaTrustedRouter) {
        if (trustedRouters[sender]) {
            wallet = _routerSubject(sender);
            return (wallet, true);
        }
        if (sender == address(0)) revert MissingSwapSubject();
        return (sender, false);
    }

    /// @notice Layer 1 hit on the LP subject or, if it is a registered Safe, on its owners.
    /// @return hit The sanctioned wallet (`subject` or the first matching owner). `address(0)` if clean.
    function layer1Hit(
        address subject,
        mapping(address => TrustedMultisig) storage trustedMultisigs,
        ISanctionRegistry sanctionRegistry,
        MultisigAggregation aggregation
    ) internal view returns (address hit) {
        if (sanctionRegistry.isSanctioned(subject)) return subject;
        TrustedMultisig memory ms = trustedMultisigs[subject];
        if (!ms.trusted) return address(0);
        return _ownerLayer1Hit(subject, ms.kind, sanctionRegistry, aggregation);
    }

    function _routerSubject(address router) private view returns (address wallet) {
        try IMsgSender(router).msgSender() returns (address subject) {
            wallet = subject;
        } catch {
            revert TrustedRouterSubjectFailed(router);
        }
        if (wallet == address(0)) revert TrustedRouterSubjectFailed(router);
    }

    function _ownerLayer1Hit(
        address wallet,
        MultisigType kind,
        ISanctionRegistry sanctionRegistry,
        MultisigAggregation aggregation
    ) private view returns (address hit) {
        address[] memory owners;
        if (kind != MultisigType.GNOSIS_SAFE) return address(0);
        try IGnosisSafeOwners(wallet).getOwners() returns (address[] memory ownerList) {
            owners = ownerList;
        } catch {
            return address(0);
        }
        if (owners.length == 0) return address(0);

        bool anyOwnerClean;
        address firstSanctionedOwner;
        for (uint256 i; i < owners.length; ++i) {
            if (!sanctionRegistry.isSanctioned(owners[i])) {
                anyOwnerClean = true;
            } else if (firstSanctionedOwner == address(0)) {
                firstSanctionedOwner = owners[i];
                if (aggregation == MultisigAggregation.ALL_CLEAN) return owners[i];
            }
        }
        if (aggregation == MultisigAggregation.ANY_CLEAN && !anyOwnerClean) {
            return firstSanctionedOwner;
        }
    }
}
