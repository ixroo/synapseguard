// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IDepositPayable } from "./SynapseTypes.sol";

/// @title SynapseUnichainSentinel
/// @notice Unichain Sepolia cross-chain emergency circuit breaker synced from Reactive Lasna.
contract SynapseUnichainSentinel is AbstractCallback {
    error ZeroAddress();
    error NotOwner(address caller);
    error InvalidAmount();

    event UnichainSentinelFrozen(
        uint256 indexed intentId,
        address indexed actor,
        uint16 riskScore,
        bytes32 modelDigest,
        uint256 timestamp
    );
    event UnichainSentinelUnfrozen(uint256 indexed epoch, uint256 timestamp);
    event FreezeIgnored(uint256 indexed intentId, bool alreadyLocked);

    address public immutable owner;
    bool public emergencyLocked;
    uint256 public lockEpoch;
    uint256 public lockedAt;
    uint16 public lastRiskScore;
    bytes32 public lastModelDigest;
    mapping(address actor => bool) public frozenActors;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        if (address(callbackProxy_) == address(0) || callbackSender_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
    }

    /// @notice Freeze global & correlated actor permissions on Unichain Sepolia upon AI emergency verdict.
    function onCrossChainFreeze(
        address rc_,
        uint256 intentId_,
        address actor_,
        uint16 riskScore_,
        bytes32 modelDigest_
    ) external onlyServiceProvider onlyCallbackSender(rc_) {
        if (emergencyLocked && frozenActors[actor_]) {
            emit FreezeIgnored(intentId_, true);
            return;
        }
        emergencyLocked = true;
        lockEpoch += 1;
        lockedAt = block.timestamp;
        lastRiskScore = riskScore_;
        lastModelDigest = modelDigest_;
        if (actor_ != address(0)) {
            frozenActors[actor_] = true;
        }
        emit UnichainSentinelFrozen(intentId_, actor_, riskScore_, modelDigest_, block.timestamp);
    }

    /// @notice Restore Unichain Sepolia sentinel when Base Sepolia governance triggers VaultUnfrozen.
    function onCrossChainUnfreeze(address rc_, uint256 epoch_, address actorToClear_)
        external
        onlyServiceProvider
        onlyCallbackSender(rc_)
    {
        emergencyLocked = false;
        if (actorToClear_ != address(0)) {
            frozenActors[actorToClear_] = false;
        }
        emit UnichainSentinelUnfrozen(epoch_, block.timestamp);
    }

    function clearActor(address actor_) external onlyOwner {
        frozenActors[actor_] = false;
    }

    function coverDebt() external {
        _coverDebt();
    }

    function depositToProxy() external payable {
        if (msg.value == 0) revert InvalidAmount();
        IDepositPayable(address(_SERVICE_PROVIDER)).depositTo{ value: msg.value }(address(this));
    }
}
