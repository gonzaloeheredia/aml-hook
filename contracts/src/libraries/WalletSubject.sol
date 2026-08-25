// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGnosisSafeOwners} from "../interfaces/external/IGnosisSafeOwners.sol";
import {IMsgSender} from "../interfaces/external/IMsgSender.sol";
import {ISanctionRegistry} from "../interfaces/registries/ISanctionRegistry.sol";

enum MultisigAggregation {
    ALL_CLEAN,
    ANY_CLEAN
}

enum MultisigType {
    NONE,
    GNOSIS_SAFE
}

struct TrustedMultisig {
    bool trusted;
    MultisigType kind;
}

/// @title §3.5 subject resolution — trusted router `msgSender()`, then optional Safe L1.
library WalletSubject {
    error MissingSwapSubject();
    error TrustedRouterSubjectFailed(address router);
    error SanctionHit(address wallet);

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
}
