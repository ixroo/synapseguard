// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ISynapseEvents, IDepositPayable, SynapseTypes } from "./SynapseTypes.sol";

/// @title SynapseReactor
/// @notice Reactive Lasna Coordinator implementing bidirectional Base Sepolia <-> AI <-> Unichain Sepolia orchestration.
/// @dev Lazily subscribes/unsubscribes Cron10 only while intents are pending so idle blocks cost zero lREACT.
contract SynapseReactor is AbstractReactive {
    enum ReactorState {
        NONE,
        PENDING_AI,
        AI_DISPATCHED,
        SETTLED,
        TIMED_OUT_DISPATCHED
    }

    struct TrackedIntent {
        address actor;
        address token;
        uint256 amount;
        uint16 anomalyHintBps;
        uint64 deadlineTs;
        bytes32 contextHash;
        ReactorState state;
        uint8 outcome;
        uint16 riskScore;
        bytes32 modelDigest;
    }

    error NotOwner(address caller);
    error ZeroAddress();
    error InvalidChainId();
    error AlreadyConfigured();
    error NotPendingAI(uint256 intentId, ReactorState currentState);
    error InvalidAISignature();
    error ExpiredVerdict(uint64 expiryTs, uint256 nowTs);
    error InvalidDecision(uint8 decision);

    event TargetsConfigured(
        uint256 indexed baseChainId,
        address indexed baseVault,
        uint256 unichainChainId,
        address unichainSentinel,
        address aiSigner
    );
    event AIReviewRequested(
        uint256 indexed intentId,
        address indexed actor,
        uint256 amount,
        uint16 anomalyHintBps,
        uint64 deadlineTs,
        bytes32 digest
    );
    event AIVerdictSubmitted(
        uint256 indexed intentId,
        uint8 indexed decision,
        uint16 riskScore,
        bytes32 modelDigest,
        uint256 timestamp
    );
    event CrossChainFreezeDispatched(uint256 indexed intentId, address indexed actor, uint16 riskScore);
    event TimeoutWatchdogDispatched(uint256 indexed intentId, uint256 detectedAt);
    event ReactorStateSynced(uint256 indexed intentId, uint8 indexed outcome, bool executed, uint256 timestamp);
    event CronSubscriptionToggled(bool active, uint256 pendingCount);
    event SubscriptionsPaused();
    event SubscriptionsResumed();

    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON10_TOPIC_0 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint64 internal constant VAULT_CALLBACK_GAS_LIMIT = 1_000_000;
    uint64 internal constant SENTINEL_CALLBACK_GAS_LIMIT = 600_000;
    uint256 internal constant MAX_CRON_SWEEP_BATCH = 20;

    uint256 internal immutable _TOPIC_INTENT_PROPOSED;
    uint256 internal immutable _TOPIC_INTENT_SETTLED;
    uint256 internal immutable _TOPIC_VAULT_UNFROZEN;

    address public immutable owner;
    uint256 public baseChainId;
    uint256 public unichainChainId;
    address public baseVault;
    address public unichainSentinel;
    address public aiSigner;

    bool public configured;
    bool public cronSubscribed;
    address public lastFrozenActor;

    uint256[] private _activeIntentIds;
    mapping(uint256 intentId => uint256 indexPlusOne) private _activeIndexPlusOne;
    mapping(uint256 intentId => TrackedIntent) private _trackedIntents;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor() payable {
        owner = msg.sender;
        _TOPIC_INTENT_PROPOSED = uint256(ISynapseEvents.IntentProposed.selector);
        _TOPIC_INTENT_SETTLED = uint256(ISynapseEvents.IntentSettled.selector);
        _TOPIC_VAULT_UNFROZEN = uint256(ISynapseEvents.VaultUnfrozen.selector);
    }

    /// @notice Configure Base Sepolia + Unichain Sepolia contracts and subscribe to exact Base Vault event topics.
    function configureAndSubscribe(
        uint256 baseChainId_,
        address baseVault_,
        uint256 unichainChainId_,
        address unichainSentinel_,
        address aiSigner_
    ) external onlyOwner {
        if (configured) revert AlreadyConfigured();
        if (baseChainId_ == 0 || unichainChainId_ == 0) revert InvalidChainId();
        if (baseVault_ == address(0) || unichainSentinel_ == address(0) || aiSigner_ == address(0)) {
            revert ZeroAddress();
        }

        configured = true;
        baseChainId = baseChainId_;
        baseVault = baseVault_;
        unichainChainId = unichainChainId_;
        unichainSentinel = unichainSentinel_;
        aiSigner = aiSigner_;

        _subscribeOriginVault();
        emit TargetsConfigured(baseChainId_, baseVault_, unichainChainId_, unichainSentinel_, aiSigner_);
    }

    function setAISigner(address newSigner_) external onlyOwner {
        if (newSigner_ == address(0)) revert ZeroAddress();
        aiSigner = newSigner_;
    }

    function pause() external onlyOwner {
        if (configured) _unsubscribeOriginVault();
        _disableCronIfActive();
        emit SubscriptionsPaused();
    }

    function resume() external payable onlyOwner {
        _coverDebt();
        if (configured) _subscribeOriginVault();
        if (_activeIntentIds.length > 0 && !cronSubscribed) {
            _enableCron();
        }
        emit SubscriptionsResumed();
    }

    function coverDebt() external payable {
        _coverDebt();
    }

    function depositToSystem() external payable {
        IDepositPayable(address(SYSTEM)).depositTo{ value: msg.value }(address(this));
    }

    /// @inheritdoc IReactive
    /// @dev Return early cleanly instead of reverting so Lasna reactions never drain gas in retries.
    function react(LogRecord calldata log_) external onlySystem {
        if (!configured) return;

        if (log_.chainId == block.chainid && log_.contractAddress == LEGACY_SYSTEM_ADDR && log_.topic0 == CRON10_TOPIC_0) {
            _handleCronWatchdog();
            return;
        }

        if (log_.chainId != baseChainId || log_.contractAddress != baseVault) return;

        if (log_.topic0 == _TOPIC_INTENT_PROPOSED) {
            _handleIntentProposed(log_);
        } else if (log_.topic0 == _TOPIC_INTENT_SETTLED) {
            _handleIntentSettled(log_);
        } else if (log_.topic0 == _TOPIC_VAULT_UNFROZEN) {
            _handleVaultUnfrozen(log_);
        }
    }

    /// @notice Submit a cryptographically signed Gemini AI decision and dispatch cross-chain callbacks via SYSTEM.
    function submitAIVerdict(
        uint256 intentId_,
        uint8 decision_,
        uint16 riskScore_,
        uint64 expiryTs_,
        bytes32 modelDigest_,
        bytes calldata signature_
    ) external {
        if (decision_ > SynapseTypes.DECISION_FREEZE_EMERGENCY) revert InvalidDecision(decision_);
        TrackedIntent storage record = _trackedIntents[intentId_];
        if (record.state != ReactorState.PENDING_AI) revert NotPendingAI(intentId_, record.state);
        if (block.timestamp > expiryTs_) revert ExpiredVerdict(expiryTs_, block.timestamp);

        bytes32 digest = SynapseTypes.verdictEthSignedHash(
            baseChainId,
            baseVault,
            intentId_,
            decision_,
            riskScore_,
            expiryTs_,
            modelDigest_
        );
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature_);
        if (err != ECDSA.RecoverError.NoError || recovered != aiSigner) revert InvalidAISignature();

        record.state = ReactorState.AI_DISPATCHED;
        record.riskScore = riskScore_;
        record.modelDigest = modelDigest_;

        emit AIVerdictSubmitted(intentId_, decision_, riskScore_, modelDigest_, block.timestamp);

        bytes memory vaultPayload = abi.encodeWithSignature(
            "onAIVerdictCallback(address,uint256,uint8,uint16,uint64,bytes32,bytes)",
            address(0),
            intentId_,
            decision_,
            riskScore_,
            expiryTs_,
            modelDigest_,
            signature_
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: baseChainId,
                recipient: baseVault,
                gasLimit: VAULT_CALLBACK_GAS_LIMIT,
                payload: vaultPayload
            })
        );

        if (decision_ == SynapseTypes.DECISION_FREEZE_EMERGENCY) {
            lastFrozenActor = record.actor;
            bytes memory sentinelPayload = abi.encodeWithSignature(
                "onCrossChainFreeze(address,uint256,address,uint16,bytes32)",
                address(0),
                intentId_,
                record.actor,
                riskScore_,
                modelDigest_
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: unichainChainId,
                    recipient: unichainSentinel,
                    gasLimit: SENTINEL_CALLBACK_GAS_LIMIT,
                    payload: sentinelPayload
                })
            );
            emit CrossChainFreezeDispatched(intentId_, record.actor, riskScore_);
        }
    }

    function _handleIntentProposed(LogRecord calldata log_) internal {
        uint256 intentId = log_.topic1;
        TrackedIntent storage existing = _trackedIntents[intentId];
        if (existing.state != ReactorState.NONE) return;

        address actor = address(uint160(log_.topic2));
        address token = address(uint160(log_.topic3));
        (uint256 amount, uint16 anomalyHintBps, uint64 deadlineTs, bytes32 contextHash) =
            abi.decode(log_.data, (uint256, uint16, uint64, bytes32));

        _trackedIntents[intentId] = TrackedIntent({
            actor: actor,
            token: token,
            amount: amount,
            anomalyHintBps: anomalyHintBps,
            deadlineTs: deadlineTs,
            contextHash: contextHash,
            state: ReactorState.PENDING_AI,
            outcome: 0,
            riskScore: 0,
            modelDigest: bytes32(0)
        });

        _addActiveIntent(intentId);
        if (!cronSubscribed) {
            _enableCron();
        }

        bytes32 requestDigest = keccak256(abi.encode(intentId, actor, token, amount, anomalyHintBps, deadlineTs, contextHash));
        emit AIReviewRequested(intentId, actor, amount, anomalyHintBps, deadlineTs, requestDigest);
    }

    function _handleIntentSettled(LogRecord calldata log_) internal {
        uint256 intentId = log_.topic1;
        uint8 outcome = uint8(log_.topic2);
        bool executed = log_.topic3 != 0;
        (uint256 settledAt, bytes32 modelDigest) = abi.decode(log_.data, (uint256, bytes32));

        TrackedIntent storage record = _trackedIntents[intentId];
        if (record.state == ReactorState.SETTLED) return;

        record.state = ReactorState.SETTLED;
        record.outcome = outcome;
        if (modelDigest != bytes32(0)) {
            record.modelDigest = modelDigest;
        }

        _removeActiveIntent(intentId);
        if (_activeIntentIds.length == 0) {
            _disableCronIfActive();
        }

        emit ReactorStateSynced(intentId, outcome, executed, settledAt);
    }

    function _handleVaultUnfrozen(LogRecord calldata log_) internal {
        uint256 epoch = log_.topic1;
        bytes memory sentinelPayload = abi.encodeWithSignature(
            "onCrossChainUnfreeze(address,uint256,address)",
            address(0),
            epoch,
            lastFrozenActor
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: unichainChainId,
                recipient: unichainSentinel,
                gasLimit: SENTINEL_CALLBACK_GAS_LIMIT,
                payload: sentinelPayload
            })
        );
    }

    function _handleCronWatchdog() internal {
        uint256 len = _activeIntentIds.length;
        if (len == 0) {
            _disableCronIfActive();
            return;
        }

        uint256 checked = 0;
        uint256 idx = 0;
        while (idx < _activeIntentIds.length && checked < MAX_CRON_SWEEP_BATCH) {
            uint256 intentId = _activeIntentIds[idx];
            TrackedIntent storage record = _trackedIntents[intentId];
            checked += 1;

            if (record.state == ReactorState.PENDING_AI && block.timestamp > record.deadlineTs) {
                record.state = ReactorState.TIMED_OUT_DISPATCHED;
                bytes memory payload = abi.encodeWithSignature(
                    "onTimeoutFallbackCallback(address,uint256)",
                    address(0),
                    intentId
                );
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: baseChainId,
                        recipient: baseVault,
                        gasLimit: VAULT_CALLBACK_GAS_LIMIT,
                        payload: payload
                    })
                );
                emit TimeoutWatchdogDispatched(intentId, block.timestamp);
            }
            idx += 1;
        }
    }

    function _subscribeOriginVault() internal {
        SYSTEM.subscribe(baseChainId, baseVault, _TOPIC_INTENT_PROPOSED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(baseChainId, baseVault, _TOPIC_INTENT_SETTLED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(baseChainId, baseVault, _TOPIC_VAULT_UNFROZEN, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribeOriginVault() internal {
        SYSTEM.unsubscribe(baseChainId, baseVault, _TOPIC_INTENT_PROPOSED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(baseChainId, baseVault, _TOPIC_INTENT_SETTLED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(baseChainId, baseVault, _TOPIC_VAULT_UNFROZEN, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _enableCron() internal {
        cronSubscribed = true;
        SYSTEM.subscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            CRON10_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit CronSubscriptionToggled(true, _activeIntentIds.length);
    }

    function _disableCronIfActive() internal {
        if (!cronSubscribed) return;
        cronSubscribed = false;
        SYSTEM.unsubscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            CRON10_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit CronSubscriptionToggled(false, _activeIntentIds.length);
    }

    function _addActiveIntent(uint256 intentId_) internal {
        if (_activeIndexPlusOne[intentId_] != 0) return;
        _activeIntentIds.push(intentId_);
        _activeIndexPlusOne[intentId_] = _activeIntentIds.length;
    }

    function _removeActiveIntent(uint256 intentId_) internal {
        uint256 idxPlus = _activeIndexPlusOne[intentId_];
        if (idxPlus == 0) return;
        uint256 idx = idxPlus - 1;
        uint256 lastIdx = _activeIntentIds.length - 1;
        if (idx != lastIdx) {
            uint256 movedId = _activeIntentIds[lastIdx];
            _activeIntentIds[idx] = movedId;
            _activeIndexPlusOne[movedId] = idx + 1;
        }
        _activeIntentIds.pop();
        delete _activeIndexPlusOne[intentId_];
    }

    function getActiveIntentIds() external view returns (uint256[] memory) {
        return _activeIntentIds;
    }

    function getTrackedIntent(uint256 intentId_) external view returns (TrackedIntent memory) {
        return _trackedIntents[intentId_];
    }
}
