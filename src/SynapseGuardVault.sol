// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ISynapseEvents, IDepositPayable, SynapseTypes } from "./SynapseTypes.sol";

/// @title SynapseGuardVault
/// @notice Base Sepolia Origin + Destination Vault protected by Reactive Lasna callbacks and AI ECDSA signatures.
/// @dev Uses block.timestamp strictly for deadlines (compatible with Base Sepolia's 200ms blocks).
contract SynapseGuardVault is AbstractCallback, ReentrancyGuard, ISynapseEvents {
    using SafeERC20 for IERC20;

    enum VaultIntentStatus {
        NONE,
        PENDING,
        EXECUTED,
        REJECTED_BY_AI,
        FROZEN_BY_AI,
        TIMED_OUT,
        REJECTED_GUARDRAIL,
        CANCELLED
    }

    struct Intent {
        address actor;
        address recipient;
        address token; // address(0) = native ETH, otherwise ERC-20
        uint256 amount;
        uint16 anomalyHintBps;
        uint64 createdAt;
        uint64 deadlineTs;
        bytes32 contextHash;
        VaultIntentStatus status;
    }

    error NotOwner(address caller);
    error ZeroAddress();
    error InvalidAmount();
    error InvalidTTL(uint64 ttlSeconds);
    error VaultIsFrozen();
    error VaultNotFrozen();
    error InsufficientVaultLiquidity(uint256 requested, uint256 available);
    error NotIntentActor(address caller, address expected);
    error IntentNotPending(uint256 intentId, VaultIntentStatus current);
    error IntentStillActive(uint256 deadlineTs, uint256 currentTs);

    event AISignerUpdated(address indexed oldSigner, address indexed newSigner);
    event PolicyUpdated(uint256 maxSingleIntentAmount, uint64 minTtlSeconds, uint64 maxTtlSeconds);
    event CallbackIgnored(uint256 indexed intentId, VaultIntentStatus currentStatus);
    event CallbackRejected(uint256 indexed intentId, string reason);
    event CollateralDeposited(address indexed depositor, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed to, address indexed token, uint256 amount);

    address public immutable owner;
    address public aiSigner;

    bool public emergencyFrozen;
    uint256 public freezeEpoch;
    uint256 public frozenAt;
    uint256 public nextIntentId = 1;
    uint256 public maxSingleIntentAmount;
    uint64 public minTtlSeconds = 20;
    uint64 public maxTtlSeconds = 3600;

    /// @notice Unencumbered liquidity accounting separating native ETH gas reserves from user vault deposits.
    mapping(address token => uint256 balance) public vaultLiquidity;
    mapping(uint256 intentId => Intent) private _intents;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        address aiSigner_,
        uint256 maxSingleIntentAmount_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        if (address(callbackProxy_) == address(0) || callbackSender_ == address(0) || aiSigner_ == address(0)) {
            revert ZeroAddress();
        }
        owner = msg.sender;
        aiSigner = aiSigner_;
        maxSingleIntentAmount = maxSingleIntentAmount_;
    }

    /// @notice Update authorized AI ECDSA signer key.
    function setAISigner(address newSigner_) external onlyOwner {
        if (newSigner_ == address(0)) revert ZeroAddress();
        emit AISignerUpdated(aiSigner, newSigner_);
        aiSigner = newSigner_;
    }

    /// @notice Update deterministic vault policy bounds.
    function setPolicy(uint256 maxSingleIntentAmount_, uint64 minTtlSeconds_, uint64 maxTtlSeconds_) external onlyOwner {
        if (minTtlSeconds_ == 0 || minTtlSeconds_ > maxTtlSeconds_) revert InvalidTTL(minTtlSeconds_);
        maxSingleIntentAmount = maxSingleIntentAmount_;
        minTtlSeconds = minTtlSeconds_;
        maxTtlSeconds = maxTtlSeconds_;
        emit PolicyUpdated(maxSingleIntentAmount_, minTtlSeconds_, maxTtlSeconds_);
    }

    /// @notice Deposit native ETH liquidity into vault accounting (separate from callback gas reserve).
    function depositEth() external payable {
        if (msg.value == 0) revert InvalidAmount();
        vaultLiquidity[address(0)] += msg.value;
        emit CollateralDeposited(msg.sender, address(0), msg.value);
    }

    /// @notice Deposit ERC-20 liquidity into vault accounting.
    function depositToken(address token_, uint256 amount_) external nonReentrant {
        if (token_ == address(0)) revert ZeroAddress();
        if (amount_ == 0) revert InvalidAmount();
        vaultLiquidity[token_] += amount_;
        IERC20(token_).safeTransferFrom(msg.sender, address(this), amount_);
        emit CollateralDeposited(msg.sender, token_, amount_);
    }

    /// @notice Governance withdrawal of ERC-20 or native vault liquidity when vault is not frozen.
    function withdrawVaultLiquidity(address token_, address to_, uint256 amount_) external nonReentrant onlyOwner {
        if (emergencyFrozen) revert VaultIsFrozen();
        if (to_ == address(0)) revert ZeroAddress();
        uint256 avail = vaultLiquidity[token_];
        if (amount_ == 0 || amount_ > avail) revert InsufficientVaultLiquidity(amount_, avail);
        vaultLiquidity[token_] = avail - amount_;
        emit CollateralWithdrawn(to_, token_, amount_);
        _payoutAsset(token_, to_, amount_);
    }

    /// @notice Settle any callback proxy debt using gas reserve ETH held outside vaultLiquidity.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Deposit ETH directly into the Callback Proxy reserves for this vault contract.
    function depositToProxy() external payable {
        if (msg.value == 0) revert InvalidAmount();
        IDepositPayable(address(_SERVICE_PROVIDER)).depositTo{ value: msg.value }(address(this));
    }

    /// @notice Propose a guarded intent; emits IntentProposed for Reactive Lasna and downstream Gemini review.
    function proposeIntent(
        address recipient_,
        address token_,
        uint256 amount_,
        uint16 anomalyHintBps_,
        uint64 ttlSeconds_,
        bytes32 contextHash_
    ) external returns (uint256 intentId) {
        if (emergencyFrozen) revert VaultIsFrozen();
        if (recipient_ == address(0)) revert ZeroAddress();
        if (amount_ == 0) revert InvalidAmount();
        if (ttlSeconds_ < minTtlSeconds || ttlSeconds_ > maxTtlSeconds) revert InvalidTTL(ttlSeconds_);

        uint256 avail = vaultLiquidity[token_];
        if (amount_ > avail) revert InsufficientVaultLiquidity(amount_, avail);

        intentId = nextIntentId++;
        uint64 deadlineTs = uint64(block.timestamp) + ttlSeconds_;

        _intents[intentId] = Intent({
            actor: msg.sender,
            recipient: recipient_,
            token: token_,
            amount: amount_,
            anomalyHintBps: anomalyHintBps_,
            createdAt: uint64(block.timestamp),
            deadlineTs: deadlineTs,
            contextHash: contextHash_,
            status: VaultIntentStatus.PENDING
        });

        emit IntentProposed(
            intentId,
            msg.sender,
            token_,
            amount_,
            anomalyHintBps_,
            deadlineTs,
            contextHash_
        );
    }

    /// @notice Settle a pending intent via Reactive callback after validating Proxy, Reactor, AI ECDSA sig, and invariants.
    function onAIVerdictCallback(
        address rc_,
        uint256 intentId_,
        uint8 decision_,
        uint16 riskScore_,
        uint64 expiryTs_,
        bytes32 modelDigest_,
        bytes calldata signature_
    ) external nonReentrant onlyServiceProvider onlyCallbackSender(rc_) {
        Intent storage intent = _intents[intentId_];
        if (intent.status != VaultIntentStatus.PENDING) {
            // Return early without reverting so duplicate/late callbacks don't fail or desync reserves.
            emit CallbackIgnored(intentId_, intent.status);
            return;
        }

        if (block.timestamp > intent.deadlineTs || block.timestamp > expiryTs_) {
            intent.status = VaultIntentStatus.TIMED_OUT;
            emit CallbackRejected(intentId_, "EXPIRED_TIMESTAMP");
            emit IntentSettled(intentId_, SynapseTypes.OUTCOME_TIMED_OUT, false, block.timestamp, modelDigest_);
            return;
        }

        bytes32 digest = SynapseTypes.verdictEthSignedHash(
            block.chainid,
            address(this),
            intentId_,
            decision_,
            riskScore_,
            expiryTs_,
            modelDigest_
        );
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature_);
        if (err != ECDSA.RecoverError.NoError || recovered != aiSigner) {
            intent.status = VaultIntentStatus.REJECTED_GUARDRAIL;
            emit CallbackRejected(intentId_, "INVALID_AI_SIGNATURE");
            emit IntentSettled(intentId_, SynapseTypes.OUTCOME_REJECTED_GUARDRAIL, false, block.timestamp, modelDigest_);
            return;
        }

        if (decision_ == SynapseTypes.DECISION_FREEZE_EMERGENCY) {
            emergencyFrozen = true;
            freezeEpoch += 1;
            frozenAt = block.timestamp;
            intent.status = VaultIntentStatus.FROZEN_BY_AI;
            emit VaultEmergencyFrozen(intentId_, intent.actor, riskScore_, modelDigest_);
            emit IntentSettled(intentId_, SynapseTypes.OUTCOME_FROZEN_BY_AI, false, block.timestamp, modelDigest_);
            return;
        }

        if (decision_ == SynapseTypes.DECISION_APPROVE) {
            if (emergencyFrozen) {
                intent.status = VaultIntentStatus.REJECTED_GUARDRAIL;
                emit CallbackRejected(intentId_, "VAULT_ALREADY_FROZEN");
                emit IntentSettled(
                    intentId_,
                    SynapseTypes.OUTCOME_REJECTED_GUARDRAIL,
                    false,
                    block.timestamp,
                    modelDigest_
                );
                return;
            }
            if (maxSingleIntentAmount > 0 && intent.amount > maxSingleIntentAmount) {
                intent.status = VaultIntentStatus.REJECTED_GUARDRAIL;
                emit CallbackRejected(intentId_, "EXCEEDS_ONCHAIN_CAP");
                emit IntentSettled(
                    intentId_,
                    SynapseTypes.OUTCOME_REJECTED_GUARDRAIL,
                    false,
                    block.timestamp,
                    modelDigest_
                );
                return;
            }
            uint256 avail = vaultLiquidity[intent.token];
            if (intent.amount > avail) {
                intent.status = VaultIntentStatus.REJECTED_GUARDRAIL;
                emit CallbackRejected(intentId_, "INSUFFICIENT_VAULT_LIQUIDITY");
                emit IntentSettled(
                    intentId_,
                    SynapseTypes.OUTCOME_REJECTED_GUARDRAIL,
                    false,
                    block.timestamp,
                    modelDigest_
                );
                return;
            }

            vaultLiquidity[intent.token] = avail - intent.amount;
            intent.status = VaultIntentStatus.EXECUTED;
            emit IntentSettled(intentId_, SynapseTypes.OUTCOME_EXECUTED, true, block.timestamp, modelDigest_);
            _payoutAsset(intent.token, intent.recipient, intent.amount);
            return;
        }

        intent.status = VaultIntentStatus.REJECTED_BY_AI;
        emit IntentSettled(intentId_, SynapseTypes.OUTCOME_REJECTED_BY_AI, false, block.timestamp, modelDigest_);
    }

    /// @notice Triggered by Reactive Lasna Cron10 watchdog when no AI verdict arrived before deadlineTs.
    function onTimeoutFallbackCallback(address rc_, uint256 intentId_)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(rc_)
    {
        Intent storage intent = _intents[intentId_];
        if (intent.status != VaultIntentStatus.PENDING) {
            emit CallbackIgnored(intentId_, intent.status);
            return;
        }
        intent.status = VaultIntentStatus.TIMED_OUT;
        emit IntentSettled(intentId_, SynapseTypes.OUTCOME_TIMED_OUT, false, block.timestamp, bytes32(0));
    }

    /// @notice Permissionless self-rescue timeout after expiry in case callbacks are paused.
    function cancelExpiredIntent(uint256 intentId_) external {
        Intent storage intent = _intents[intentId_];
        if (intent.status != VaultIntentStatus.PENDING) revert IntentNotPending(intentId_, intent.status);
        if (msg.sender != intent.actor && msg.sender != owner) revert NotIntentActor(msg.sender, intent.actor);
        if (block.timestamp <= intent.deadlineTs) revert IntentStillActive(intent.deadlineTs, block.timestamp);
        intent.status = VaultIntentStatus.CANCELLED;
        emit IntentSettled(intentId_, SynapseTypes.OUTCOME_TIMED_OUT, false, block.timestamp, bytes32(0));
    }

    /// @notice Governance recovery unfreezing Base Sepolia Vault and emitting VaultUnfrozen for Unichain sync.
    function unfreezeVault() external onlyOwner {
        if (!emergencyFrozen) revert VaultNotFrozen();
        emergencyFrozen = false;
        emit VaultUnfrozen(freezeEpoch, block.timestamp);
    }

    function getIntent(uint256 intentId_) external view returns (Intent memory) {
        return _intents[intentId_];
    }

    function _payoutAsset(address token_, address to_, uint256 amount_) internal {
        if (token_ == address(0)) {
            (bool ok,) = payable(to_).call{ value: amount_ }("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token_).safeTransfer(to_, amount_);
        }
    }
}
