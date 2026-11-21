// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IDepositPayable } from "../../src/SynapseTypes.sol";

/// @notice Test double for a destination-chain Callback Proxy that enforces Reactive's 160-bit first-arg injection.
contract MockCallbackProxy is IPayable, IDepositPayable {
    mapping(address recipient => uint256 reserve) public reserves;
    mapping(address recipient => uint256 debtAmount) public debts;

    receive() external payable {
        _creditAccount(msg.sender, msg.value);
    }

    function depositTo(address recipient_) external payable {
        _creditAccount(recipient_, msg.value);
    }

    function _creditAccount(address recipient_, uint256 value_) internal {
        uint256 owed = debts[recipient_];
        if (value_ <= owed) {
            debts[recipient_] = owed - value_;
        } else {
            debts[recipient_] = 0;
            reserves[recipient_] += value_ - owed;
        }
    }

    function debt(address contract_) external view returns (uint256) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    function pullPayment(address payer_, uint256 amount_) external {
        IPayer(payable(payer_)).pay(amount_);
        if (amount_ <= debts[payer_]) {
            debts[payer_] -= amount_;
        } else {
            debts[payer_] = 0;
        }
    }

    /// @notice Deliver a callback while overwriting bytes [4:36] (first address param) with `injectedRc_`.
    function deliverCallback(address recipient_, address injectedRc_, bytes memory rawPayload_)
        external
        returns (bool ok, bytes memory ret)
    {
        bytes memory patched = _overwriteFirstAddressWord(rawPayload_, injectedRc_);
        return recipient_.call(patched);
    }

    function _overwriteFirstAddressWord(bytes memory payload_, address injectedRc_)
        internal
        pure
        returns (bytes memory patched)
    {
        require(payload_.length >= 36, "MockProxy: payload < 36 bytes");
        patched = new bytes(payload_.length);
        for (uint256 i = 0; i < 4; ++i) {
            patched[i] = payload_[i];
        }
        bytes32 word = bytes32(uint256(uint160(injectedRc_)));
        assembly {
            mstore(add(patched, 36), word)
        }
        for (uint256 i = 36; i < payload_.length; ++i) {
            patched[i] = payload_[i];
        }
    }
}

/// @notice Test double for Reactive Lasna SYSTEM (`0x8888...8888`) tracking exact 6-arg subscriptions and callbacks.
contract MockSystemContract is ISystemContract, IDepositPayable {
    struct QueuedCallback {
        address reactiveContract;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
        bool delivered;
    }

    mapping(address payer => uint256 reserve) public reserves;
    mapping(address payer => uint256 debtAmount) public debts;
    mapping(address subscriber => mapping(bytes32 subKey => bool active)) public subscriptions;
    mapping(address subscriber => uint256 count) public activeSubscriptionCount;
    mapping(address subscriber => uint256 calls) public subscribeCallCount;
    mapping(address subscriber => uint256 calls) public unsubscribeCallCount;

    QueuedCallback[] private _callbacks;

    receive() external payable {
        _creditAccount(msg.sender, msg.value);
    }

    function depositTo(address recipient_) external payable {
        _creditAccount(recipient_, msg.value);
    }

    function _creditAccount(address recipient_, uint256 value_) internal {
        uint256 owed = debts[recipient_];
        if (value_ <= owed) {
            debts[recipient_] = owed - value_;
        } else {
            debts[recipient_] = 0;
            reserves[recipient_] += value_ - owed;
        }
    }

    function debt(address contract_) external view returns (uint256) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        subscribeCallCount[msg.sender] += 1;
        bytes32 key = subKey(chain_id, _contract, topic_0, topic_1, topic_2, topic_3);
        if (!subscriptions[msg.sender][key]) {
            subscriptions[msg.sender][key] = true;
            activeSubscriptionCount[msg.sender] += 1;
        }
    }

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        unsubscribeCallCount[msg.sender] += 1;
        bytes32 key = subKey(chain_id, _contract, topic_0, topic_1, topic_2, topic_3);
        if (subscriptions[msg.sender][key]) {
            subscriptions[msg.sender][key] = false;
            activeSubscriptionCount[msg.sender] -= 1;
        }
    }

    function requestCallback(CallbackVersion version_, bytes memory config_) external {
        if (version_ == CallbackVersion.V_1_0) {
            CallbackConfiguration_V_1_0 memory cfg = abi.decode(config_, (CallbackConfiguration_V_1_0));
            _enqueueCallback(msg.sender, cfg);
        }
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        _enqueueCallback(msg.sender, config_);
    }

    function _enqueueCallback(address rc_, CallbackConfiguration_V_1_0 memory config_) internal {
        _callbacks.push(
            QueuedCallback({
                reactiveContract: rc_,
                chainId: config_.chainId,
                recipient: config_.recipient,
                gasLimit: config_.gasLimit,
                payload: config_.payload,
                delivered: false
            })
        );
    }

    function triggerReact(address rc_, IReactive.LogRecord calldata log_) external {
        IReactive(payable(rc_)).react(log_);
    }

    function deliverCallbackAt(uint256 index_, MockCallbackProxy proxy_)
        external
        returns (bool ok, bytes memory ret)
    {
        QueuedCallback storage cb = _callbacks[index_];
        require(!cb.delivered, "MockSystem: already delivered");
        cb.delivered = true;
        return proxy_.deliverCallback(cb.recipient, cb.reactiveContract, cb.payload);
    }

    function queuedCallbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function getQueuedCallback(uint256 index_) external view returns (QueuedCallback memory) {
        return _callbacks[index_];
    }

    function isSubscribed(
        address subscriber_,
        uint256 chainId_,
        address contractAddr_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external view returns (bool) {
        return subscriptions[subscriber_][subKey(chainId_, contractAddr_, topic0_, topic1_, topic2_, topic3_)];
    }

    function subKey(
        uint256 chainId_,
        address contractAddr_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId_, contractAddr_, topic0_, topic1_, topic2_, topic3_));
    }
}
