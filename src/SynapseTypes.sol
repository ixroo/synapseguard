// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SynapseTypes
/// @notice Shared constants, enums, and EIP-191 digest helper used across Base Sepolia, Lasna, and Unichain Sepolia.
library SynapseTypes {
    uint8 internal constant DECISION_REJECT = 0;
    uint8 internal constant DECISION_APPROVE = 1;
    uint8 internal constant DECISION_FREEZE_EMERGENCY = 2;

    uint8 internal constant OUTCOME_REJECTED_BY_AI = 1;
    uint8 internal constant OUTCOME_EXECUTED = 2;
    uint8 internal constant OUTCOME_FROZEN_BY_AI = 3;
    uint8 internal constant OUTCOME_TIMED_OUT = 4;
    uint8 internal constant OUTCOME_REJECTED_GUARDRAIL = 5;

    /// @notice Compute the canonical EIP-191 digest signed by the AI Risk Reviewer and verified on both Lasna and Base Sepolia.
    function verdictEthSignedHash(
        uint256 destChainId_,
        address vault_,
        uint256 intentId_,
        uint8 decision_,
        uint16 riskScore_,
        uint64 expiryTs_,
        bytes32 modelDigest_
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                destChainId_,
                vault_,
                intentId_,
                decision_,
                riskScore_,
                expiryTs_,
                modelDigest_
            )
        );
        return MessageHashUtils.toEthSignedMessageHash(structHash);
    }
}

/// @title ISynapseEvents
/// @notice Canonical event signatures and topic0 selectors shared between Origin/Destination Vault and Lasna Reactor.
interface ISynapseEvents {
    event IntentProposed(
        uint256 indexed intentId,
        address indexed actor,
        address indexed token,
        uint256 amount,
        uint16 anomalyHintBps,
        uint64 deadlineTs,
        bytes32 contextHash
    );

    event IntentSettled(
        uint256 indexed intentId,
        uint8 indexed outcome,
        bool indexed executed,
        uint256 settledAt,
        bytes32 modelDigest
    );

    event VaultEmergencyFrozen(
        uint256 indexed intentId,
        address indexed actor,
        uint16 riskScore,
        bytes32 modelDigest
    );

    event VaultUnfrozen(uint256 indexed epoch, uint256 timestamp);
}

/// @title IDepositPayable
/// @notice Minimal extension for Reactive System Contract and Callback Proxy `depositTo(address)` prepaid reserves.
interface IDepositPayable {
    function depositTo(address recipient_) external payable;
}
