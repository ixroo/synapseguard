// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { ISynapseEvents, SynapseTypes } from "../src/SynapseTypes.sol";
import { SynapseGuardVault } from "../src/SynapseGuardVault.sol";
import { SynapseReactor } from "../src/SynapseReactor.sol";
import { SynapseUnichainSentinel } from "../src/SynapseUnichainSentinel.sol";
import { MockCallbackProxy, MockSystemContract } from "./mocks/MockReactiveInfra.sol";

contract RevertingReceiver {
    receive() external payable {
        revert("Receiver rejected ETH");
    }
}

contract SynapseGuardTest is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 internal constant LASNA_CHAIN_ID = 5318007;

    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON10_TOPIC_0 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 internal constant AI_SIGNER_PK = 0xA11CE00000000000000000000000000000000000000000000000000000000001;
    uint256 internal constant ATTACKER_PK = 0xBADD000000000000000000000000000000000000000000000000000000000002;

    address internal aiSigner;
    address internal attackerSigner;
    address internal owner = address(this);
    address internal actor = makeAddr("actor");
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    MockSystemContract internal mockSystem;
    MockCallbackProxy internal baseProxy;
    MockCallbackProxy internal unichainProxy;

    DemoToken internal token;
    SynapseReactor internal reactor;
    SynapseGuardVault internal vault;
    SynapseUnichainSentinel internal sentinel;

    uint256 internal constant MAX_SINGLE_CAP = 500 ether;

    receive() external payable { }

    function setUp() public {
        vm.warp(1_760_000_000);
        aiSigner = vm.addr(AI_SIGNER_PK);
        attackerSigner = vm.addr(ATTACKER_PK);

        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        mockSystem = MockSystemContract(payable(SYSTEM_ADDR));

        baseProxy = new MockCallbackProxy();
        unichainProxy = new MockCallbackProxy();

        // Deploy SynapseReactor on Lasna first so Vault & Sentinel receive its immutable address.
        vm.chainId(LASNA_CHAIN_ID);
        reactor = new SynapseReactor();

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        token = new DemoToken("Synapse USD", "sUSD", 18, 10_000 ether);
        vault = new SynapseGuardVault(
            IPayable(payable(address(baseProxy))),
            address(reactor),
            aiSigner,
            MAX_SINGLE_CAP
        );

        vm.chainId(UNICHAIN_SEPOLIA_CHAIN_ID);
        sentinel = new SynapseUnichainSentinel(
            IPayable(payable(address(unichainProxy))),
            address(reactor)
        );

        // Configure and subscribe Reactor on Lasna.
        vm.chainId(LASNA_CHAIN_ID);
        reactor.configureAndSubscribe(
            BASE_SEPOLIA_CHAIN_ID,
            address(vault),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(sentinel),
            aiSigner
        );

        // Seed Base Vault liquidity with ERC-20 and ETH.
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        token.faucetMint(owner, 5_000 ether);
        token.approve(address(vault), type(uint256).max);
        vault.depositToken(address(token), 1_000 ether);
        vault.depositEth{ value: 5 ether }();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _signVerdict(
        uint256 pk_,
        uint256 chainId_,
        address vaultAddr_,
        uint256 intentId_,
        uint8 decision_,
        uint16 riskScore_,
        uint64 expiryTs_,
        bytes32 modelDigest_
    ) internal pure returns (bytes memory) {
        bytes32 digest = SynapseTypes.verdictEthSignedHash(
            chainId_,
            vaultAddr_,
            intentId_,
            decision_,
            riskScore_,
            expiryTs_,
            modelDigest_
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk_, digest);
        return abi.encodePacked(r, s, v);
    }

    function _toLogRecord(uint256 originChainId_, Vm.Log memory entry_)
        internal
        view
        returns (IReactive.LogRecord memory rec)
    {
        rec.chainId = originChainId_;
        rec.contractAddress = entry_.emitter;
        rec.opCode = entry_.topics.length;
        rec.topic0 = entry_.topics.length > 0 ? uint256(entry_.topics[0]) : 0;
        rec.topic1 = entry_.topics.length > 1 ? uint256(entry_.topics[1]) : 0;
        rec.topic2 = entry_.topics.length > 2 ? uint256(entry_.topics[2]) : 0;
        rec.topic3 = entry_.topics.length > 3 ? uint256(entry_.topics[3]) : 0;
        rec.data = entry_.data;
        rec.blockNumber = block.number;
        rec.blockHash = uint256(blockhash(block.number > 0 ? block.number - 1 : 0));
        rec.txHash = uint256(keccak256(abi.encode(entry_.emitter, entry_.topics, entry_.data, block.timestamp)));
        rec.logIndex = 0;
    }

    function _findEventLog(Vm.Log[] memory logs_, address emitter_, bytes32 sig0_)
        internal
        pure
        returns (bool found, Vm.Log memory matched)
    {
        for (uint256 i = 0; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == sig0_) {
                return (true, logs_[i]);
            }
        }
        return (false, matched);
    }

    function _proposeOnBaseAndRelayToLasna(
        address proposer_,
        address to_,
        address tok_,
        uint256 amt_,
        uint16 hintBps_,
        uint64 ttlSec_,
        bytes32 ctxHash_
    ) internal returns (uint256 intentId) {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.recordLogs();
        vm.prank(proposer_);
        intentId = vault.proposeIntent(to_, tok_, amt_, hintBps_, ttlSec_, ctxHash_);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, Vm.Log memory propLog) = _findEventLog(
            logs,
            address(vault),
            ISynapseEvents.IntentProposed.selector
        );
        assertTrue(found, "IntentProposed log missing");

        vm.chainId(LASNA_CHAIN_ID);
        mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, propLog));
    }

    function _submitVerdictAndCompleteRoundTrip(
        uint256 intentId_,
        uint8 decision_,
        uint16 riskScore_,
        uint64 expiryTs_,
        bytes32 modelDigest_
    ) internal returns (uint256 deliveredVaultCbIdx, bool unichainDelivered) {
        bytes memory sig = _signVerdict(
            AI_SIGNER_PK,
            BASE_SEPOLIA_CHAIN_ID,
            address(vault),
            intentId_,
            decision_,
            riskScore_,
            expiryTs_,
            modelDigest_
        );

        vm.chainId(LASNA_CHAIN_ID);
        uint256 cbStart = mockSystem.queuedCallbackCount();
        vm.prank(stranger); // Permissionless submission once validly signed by Gemini AI key.
        reactor.submitAIVerdict(intentId_, decision_, riskScore_, expiryTs_, modelDigest_, sig);
        uint256 cbEnd = mockSystem.queuedCallbackCount();

        assertGe(cbEnd, cbStart + 1);
        deliveredVaultCbIdx = cbStart;

        // Deliver Base Vault callback and capture IntentSettled event.
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.recordLogs();
        (bool ok,) = mockSystem.deliverCallbackAt(cbStart, baseProxy);
        assertTrue(ok, "Base Vault callback failed");
        Vm.Log[] memory baseLogs = vm.getRecordedLogs();

        // Deliver Unichain callback if emergency freeze was queued too.
        if (cbEnd == cbStart + 2) {
            vm.chainId(UNICHAIN_SEPOLIA_CHAIN_ID);
            (bool okUni,) = mockSystem.deliverCallbackAt(cbStart + 1, unichainProxy);
            assertTrue(okUni, "Unichain Sentinel callback failed");
            unichainDelivered = true;
        }

        // Feed IntentSettled back into Lasna Reactor.
        (bool foundSettled, Vm.Log memory settledLog) = _findEventLog(
            baseLogs,
            address(vault),
            ISynapseEvents.IntentSettled.selector
        );
        if (foundSettled) {
            vm.chainId(LASNA_CHAIN_ID);
            mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, settledLog));
        }
    }

    // -------------------------------------------------------------------------
    // 1. Deployment, Initialization & Access Control
    // -------------------------------------------------------------------------

    function test_DemoTokenFaucetBoundsAndDecimals() public {
        assertEq(token.decimals(), 18);
        token.faucetMint(stranger, 1_000 ether);
        assertEq(token.balanceOf(stranger), 1_000 ether);

        vm.expectRevert(abi.encodeWithSelector(DemoToken.FaucetAmountExceeded.selector, 10_001 ether, 10_000 ether));
        token.faucetMint(stranger, 10_001 ether);
    }

    function test_VaultConstructorRejectsZeroAddresses() public {
        vm.expectRevert(SynapseGuardVault.ZeroAddress.selector);
        new SynapseGuardVault(IPayable(payable(address(0))), address(reactor), aiSigner, MAX_SINGLE_CAP);

        vm.expectRevert(SynapseGuardVault.ZeroAddress.selector);
        new SynapseGuardVault(IPayable(payable(address(baseProxy))), address(0), aiSigner, MAX_SINGLE_CAP);

        vm.expectRevert(SynapseGuardVault.ZeroAddress.selector);
        new SynapseGuardVault(IPayable(payable(address(baseProxy))), address(reactor), address(0), MAX_SINGLE_CAP);
    }

    function test_SentinelConstructorRejectsZeroAddresses() public {
        vm.expectRevert(SynapseUnichainSentinel.ZeroAddress.selector);
        new SynapseUnichainSentinel(IPayable(payable(address(0))), address(reactor));

        vm.expectRevert(SynapseUnichainSentinel.ZeroAddress.selector);
        new SynapseUnichainSentinel(IPayable(payable(address(unichainProxy))), address(0));
    }

    function test_ReactorConfigureSubscriptionsAndGuards() public {
        assertTrue(reactor.configured());
        assertEq(reactor.baseChainId(), BASE_SEPOLIA_CHAIN_ID);
        assertEq(reactor.unichainChainId(), UNICHAIN_SEPOLIA_CHAIN_ID);
        assertEq(reactor.baseVault(), address(vault));
        assertEq(reactor.unichainSentinel(), address(sentinel));
        assertEq(reactor.aiSigner(), aiSigner);
        assertEq(mockSystem.activeSubscriptionCount(address(reactor)), 3);
        assertFalse(reactor.cronSubscribed());

        assertTrue(
            mockSystem.isSubscribed(
                address(reactor),
                BASE_SEPOLIA_CHAIN_ID,
                address(vault),
                uint256(ISynapseEvents.IntentProposed.selector),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            )
        );
        assertTrue(
            mockSystem.isSubscribed(
                address(reactor),
                BASE_SEPOLIA_CHAIN_ID,
                address(vault),
                uint256(ISynapseEvents.IntentSettled.selector),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            )
        );
        assertTrue(
            mockSystem.isSubscribed(
                address(reactor),
                BASE_SEPOLIA_CHAIN_ID,
                address(vault),
                uint256(ISynapseEvents.VaultUnfrozen.selector),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            )
        );

        vm.expectRevert(SynapseReactor.AlreadyConfigured.selector);
        reactor.configureAndSubscribe(BASE_SEPOLIA_CHAIN_ID, address(vault), UNICHAIN_SEPOLIA_CHAIN_ID, address(sentinel), aiSigner);
    }

    function test_ReactorFreshDeployConfigureValidationReverts() public {
        SynapseReactor r2 = new SynapseReactor();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseReactor.NotOwner.selector, stranger));
        r2.configureAndSubscribe(BASE_SEPOLIA_CHAIN_ID, address(vault), UNICHAIN_SEPOLIA_CHAIN_ID, address(sentinel), aiSigner);

        vm.expectRevert(SynapseReactor.InvalidChainId.selector);
        r2.configureAndSubscribe(0, address(vault), UNICHAIN_SEPOLIA_CHAIN_ID, address(sentinel), aiSigner);

        vm.expectRevert(SynapseReactor.InvalidChainId.selector);
        r2.configureAndSubscribe(BASE_SEPOLIA_CHAIN_ID, address(vault), 0, address(sentinel), aiSigner);

        vm.expectRevert(SynapseReactor.ZeroAddress.selector);
        r2.configureAndSubscribe(BASE_SEPOLIA_CHAIN_ID, address(0), UNICHAIN_SEPOLIA_CHAIN_ID, address(sentinel), aiSigner);

        vm.expectRevert(SynapseReactor.ZeroAddress.selector);
        r2.configureAndSubscribe(BASE_SEPOLIA_CHAIN_ID, address(vault), UNICHAIN_SEPOLIA_CHAIN_ID, address(0), aiSigner);

        vm.expectRevert(SynapseReactor.ZeroAddress.selector);
        r2.configureAndSubscribe(BASE_SEPOLIA_CHAIN_ID, address(vault), UNICHAIN_SEPOLIA_CHAIN_ID, address(sentinel), address(0));
    }

    function test_VaultOwnerOnlyAdminSetters() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.NotOwner.selector, stranger));
        vault.setAISigner(stranger);

        vm.expectRevert(SynapseGuardVault.ZeroAddress.selector);
        vault.setAISigner(address(0));

        address newSigner = makeAddr("newSigner");
        vault.setAISigner(newSigner);
        assertEq(vault.aiSigner(), newSigner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.NotOwner.selector, stranger));
        vault.setPolicy(10 ether, 30, 600);

        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.InvalidTTL.selector, 0));
        vault.setPolicy(10 ether, 0, 600);

        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.InvalidTTL.selector, 700));
        vault.setPolicy(10 ether, 700, 600);

        vault.setPolicy(200 ether, 30, 900);
        assertEq(vault.maxSingleIntentAmount(), 200 ether);
        assertEq(vault.minTtlSeconds(), 30);
        assertEq(vault.maxTtlSeconds(), 900);
    }

    function test_ReactorPauseResumeAndSetAISigner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseReactor.NotOwner.selector, stranger));
        reactor.pause();

        reactor.pause();
        assertEq(mockSystem.activeSubscriptionCount(address(reactor)), 0);

        reactor.resume();
        assertEq(mockSystem.activeSubscriptionCount(address(reactor)), 3);

        vm.expectRevert(SynapseReactor.ZeroAddress.selector);
        reactor.setAISigner(address(0));

        address rotated = makeAddr("rotatedAI");
        reactor.setAISigner(rotated);
        assertEq(reactor.aiSigner(), rotated);
    }

    // -------------------------------------------------------------------------
    // 2. Liquidity, Debt Settlement & Prepaid Reserve Funding
    // -------------------------------------------------------------------------

    function test_DepositAndWithdrawLiquidityAndEthReserveIsolation() public {
        assertEq(vault.vaultLiquidity(address(token)), 1_000 ether);
        assertEq(vault.vaultLiquidity(address(0)), 5 ether);

        // Sending raw ETH via receive() increases contract balance without polluting vaultLiquidity[address(0)].
        (bool sent,) = address(vault).call{ value: 1 ether }("");
        assertTrue(sent);
        assertEq(address(vault).balance, 6 ether);
        assertEq(vault.vaultLiquidity(address(0)), 5 ether);

        // Withdrawals cannot exceed tracked vaultLiquidity.
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.InsufficientVaultLiquidity.selector, 5.5 ether, 5 ether));
        vault.withdrawVaultLiquidity(address(0), recipient, 5.5 ether);

        vault.withdrawVaultLiquidity(address(token), recipient, 200 ether);
        assertEq(token.balanceOf(recipient), 200 ether);
        assertEq(vault.vaultLiquidity(address(token)), 800 ether);

        vault.withdrawVaultLiquidity(address(0), recipient, 2 ether);
        assertEq(recipient.balance, 2 ether);
        assertEq(vault.vaultLiquidity(address(0)), 3 ether);
    }

    function test_DepositErrorsAndRevertingEthReceiver() public {
        vm.expectRevert(SynapseGuardVault.InvalidAmount.selector);
        vault.depositEth{ value: 0 }();

        vm.expectRevert(SynapseGuardVault.ZeroAddress.selector);
        vault.depositToken(address(0), 1 ether);

        vm.expectRevert(SynapseGuardVault.InvalidAmount.selector);
        vault.depositToken(address(token), 0);

        vm.expectRevert(SynapseGuardVault.InvalidAmount.selector);
        vault.depositToProxy{ value: 0 }();

        vm.expectRevert(SynapseUnichainSentinel.InvalidAmount.selector);
        sentinel.depositToProxy{ value: 0 }();

        RevertingReceiver badRecipient = new RevertingReceiver();
        vm.expectRevert(AbstractPayer.TransferFailed.selector);
        vault.withdrawVaultLiquidity(address(0), address(badRecipient), 0.1 ether);
    }

    function test_PrepaidReservesAndDebtSettlementAcrossAllContracts() public {
        vault.depositToProxy{ value: 0.25 ether }();
        assertEq(baseProxy.reserves(address(vault)), 0.25 ether);

        sentinel.depositToProxy{ value: 0.15 ether }();
        assertEq(unichainProxy.reserves(address(sentinel)), 0.15 ether);

        reactor.depositToSystem{ value: 2 ether }();
        assertEq(mockSystem.reserves(address(reactor)), 2 ether);

        // Debt settlement via coverDebt() + pullPayment pay().
        (bool okV,) = address(vault).call{ value: 0.5 ether }("");
        assertTrue(okV);
        baseProxy.setDebt(address(vault), 0.2 ether);
        vault.coverDebt();
        assertEq(baseProxy.debt(address(vault)), 0);

        (bool okS,) = address(sentinel).call{ value: 0.3 ether }("");
        assertTrue(okS);
        unichainProxy.setDebt(address(sentinel), 0.1 ether);
        sentinel.coverDebt();
        assertEq(unichainProxy.debt(address(sentinel)), 0);

        mockSystem.setDebt(address(reactor), 0.4 ether);
        vm.deal(address(reactor), 1 ether);
        reactor.coverDebt();
        assertEq(mockSystem.debt(address(reactor)), 0);

        // Also test proxy direct pull via IPayer.pay(amount) and InsufficientFunds revert guard.
        baseProxy.setDebt(address(vault), 0.1 ether);
        baseProxy.pullPayment(address(vault), 0.1 ether);
        assertEq(baseProxy.debt(address(vault)), 0);
    }

    function test_CronBatchSweepProcessesOverMaxBatch20AfterSettlement() public {
        // Propose 22 small intents (above MAX_CRON_SWEEP_BATCH = 20) with 25s TTL.
        uint256[] memory ids = new uint256[](22);
        for (uint256 i = 0; i < 22; ++i) {
            ids[i] = _proposeOnBaseAndRelayToLasna(
                actor,
                recipient,
                address(token),
                1 ether,
                uint16(i),
                25,
                keccak256(abi.encode("batch", i))
            );
        }
        assertEq(reactor.getActiveIntentIds().length, 22);
        assertTrue(reactor.cronSubscribed());

        vm.warp(block.timestamp + 30);
        vm.chainId(LASNA_CHAIN_ID);
        uint256 cbStart = mockSystem.queuedCallbackCount();
        mockSystem.triggerReact(
            address(reactor),
            IReactive.LogRecord({
                chainId: LASNA_CHAIN_ID,
                contractAddress: LEGACY_SYSTEM_ADDR,
                topic0: CRON10_TOPIC_0,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: abi.encode(block.number + 10),
                blockNumber: block.number + 10,
                opCode: 1,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
        // Bounded first sweep dispatches exactly 20 timeout callbacks!
        assertEq(mockSystem.queuedCallbackCount() - cbStart, 20);

        // Deliver those 20 callbacks on Base Sepolia and sync IntentSettled back to Lasna.
        for (uint256 i = 0; i < 20; ++i) {
            vm.chainId(BASE_SEPOLIA_CHAIN_ID);
            vm.recordLogs();
            (bool ok,) = mockSystem.deliverCallbackAt(cbStart + i, baseProxy);
            assertTrue(ok);
            (, Vm.Log memory sLog) = _findEventLog(
                vm.getRecordedLogs(),
                address(vault),
                ISynapseEvents.IntentSettled.selector
            );
            vm.chainId(LASNA_CHAIN_ID);
            mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, sLog));
        }

        // Now only 2 intents remain; second Cron10 tick sweeps both and unsubscribes Cron10!
        assertEq(reactor.getActiveIntentIds().length, 2);
        assertTrue(reactor.cronSubscribed());
        uint256 cbNext = mockSystem.queuedCallbackCount();
        mockSystem.triggerReact(
            address(reactor),
            IReactive.LogRecord({
                chainId: LASNA_CHAIN_ID,
                contractAddress: LEGACY_SYSTEM_ADDR,
                topic0: CRON10_TOPIC_0,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: abi.encode(block.number + 20),
                blockNumber: block.number + 20,
                opCode: 1,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
        assertEq(mockSystem.queuedCallbackCount() - cbNext, 2);

        for (uint256 i = 0; i < 2; ++i) {
            vm.chainId(BASE_SEPOLIA_CHAIN_ID);
            vm.recordLogs();
            (bool ok,) = mockSystem.deliverCallbackAt(cbNext + i, baseProxy);
            assertTrue(ok);
            (, Vm.Log memory sLog) = _findEventLog(
                vm.getRecordedLogs(),
                address(vault),
                ISynapseEvents.IntentSettled.selector
            );
            vm.chainId(LASNA_CHAIN_ID);
            mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, sLog));
        }
        assertEq(reactor.getActiveIntentIds().length, 0);
        assertFalse(reactor.cronSubscribed());
    }

    // -------------------------------------------------------------------------
    // 3. Full E2E Bidirectional Loops (Approve / Reject / Native ETH)
    // -------------------------------------------------------------------------

    function test_E2E_ApproveERC20IntentFullBidirectionalSync() public {
        uint256 amount = 120 ether;
        bytes32 ctxHash = keccak256("normal-treasury-rebalance");
        bytes32 modelDigest = keccak256("gemini-2.5-flash-lite:v1:approve");

        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            amount,
            150,
            60,
            ctxHash
        );
        assertEq(intentId, 1);

        // Lasna Reactor queued intent & lazily subscribed Cron10.
        assertTrue(reactor.cronSubscribed());
        assertEq(reactor.getActiveIntentIds().length, 1);
        SynapseReactor.TrackedIntent memory tracked = reactor.getTrackedIntent(intentId);
        assertEq(uint8(tracked.state), uint8(SynapseReactor.ReactorState.PENDING_AI));
        assertEq(tracked.actor, actor);
        assertEq(tracked.amount, amount);
        assertEq(mockSystem.activeSubscriptionCount(address(reactor)), 4); // 3 Vault + 1 Cron10

        uint64 expiryTs = uint64(block.timestamp + 45);
        _submitVerdictAndCompleteRoundTrip(
            intentId,
            SynapseTypes.DECISION_APPROVE,
            1800,
            expiryTs,
            modelDigest
        );

        // Verify Base Vault transferred ERC-20 and updated accounting cleanly.
        assertEq(token.balanceOf(recipient), amount);
        assertEq(vault.vaultLiquidity(address(token)), 1_000 ether - amount);
        SynapseGuardVault.Intent memory vIntent = vault.getIntent(intentId);
        assertEq(uint8(vIntent.status), uint8(SynapseGuardVault.VaultIntentStatus.EXECUTED));

        // Verify Lasna Reactor synced back to SETTLED and unsubscribed Cron10 lazily!
        SynapseReactor.TrackedIntent memory synced = reactor.getTrackedIntent(intentId);
        assertEq(uint8(synced.state), uint8(SynapseReactor.ReactorState.SETTLED));
        assertEq(synced.outcome, SynapseTypes.OUTCOME_EXECUTED);
        assertEq(synced.modelDigest, modelDigest);
        assertEq(reactor.getActiveIntentIds().length, 0);
        assertFalse(reactor.cronSubscribed());
        assertEq(mockSystem.activeSubscriptionCount(address(reactor)), 3);
    }

    function test_E2E_ApproveNativeEthIntent() public {
        uint256 ethAmount = 1.25 ether;
        bytes32 modelDigest = keccak256("gemini-native-eth-ok");

        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(0),
            ethAmount,
            50,
            120,
            keccak256("native-eth-payout")
        );

        _submitVerdictAndCompleteRoundTrip(
            intentId,
            SynapseTypes.DECISION_APPROVE,
            900,
            uint64(block.timestamp + 90),
            modelDigest
        );

        assertEq(recipient.balance, ethAmount);
        assertEq(vault.vaultLiquidity(address(0)), 5 ether - ethAmount);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.EXECUTED));
        assertFalse(reactor.cronSubscribed());
    }

    function test_E2E_RejectByAIIntentPreservesLiquidity() public {
        uint256 amount = 250 ether;
        bytes32 modelDigest = keccak256("gemini-high-slippage-reject");

        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            amount,
            6400,
            90,
            keccak256("anomalous-tx")
        );

        _submitVerdictAndCompleteRoundTrip(
            intentId,
            SynapseTypes.DECISION_REJECT,
            7200,
            uint64(block.timestamp + 60),
            modelDigest
        );

        assertEq(token.balanceOf(recipient), 0);
        assertEq(vault.vaultLiquidity(address(token)), 1_000 ether);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.REJECTED_BY_AI));
        assertEq(reactor.getTrackedIntent(intentId).outcome, SynapseTypes.OUTCOME_REJECTED_BY_AI);
        assertFalse(reactor.cronSubscribed());
    }

    // -------------------------------------------------------------------------
    // 4. Cross-Chain Emergency Freeze & Governance Unfreeze Round-Trip
    // -------------------------------------------------------------------------

    function test_E2E_EmergencyFreezePropagatesToUnichainAndUnfreezeRestoresBoth() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            400 ether,
            9500,
            120,
            keccak256("flash-drain-attack")
        );

        bytes32 freezeDigest = keccak256("gemini-critical-exploit-freeze");
        (, bool unichainDelivered) = _submitVerdictAndCompleteRoundTrip(
            intentId,
            SynapseTypes.DECISION_FREEZE_EMERGENCY,
            9800,
            uint64(block.timestamp + 60),
            freezeDigest
        );
        assertTrue(unichainDelivered);

        // Both Base Sepolia Vault and Unichain Sepolia Sentinel are frozen!
        assertTrue(vault.emergencyFrozen());
        assertEq(vault.freezeEpoch(), 1);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.FROZEN_BY_AI));

        assertTrue(sentinel.emergencyLocked());
        assertTrue(sentinel.frozenActors(actor));
        assertEq(sentinel.lockEpoch(), 1);
        assertEq(sentinel.lastRiskScore(), 9800);
        assertEq(sentinel.lastModelDigest(), freezeDigest);
        assertEq(reactor.lastFrozenActor(), actor);
        assertEq(reactor.getTrackedIntent(intentId).outcome, SynapseTypes.OUTCOME_FROZEN_BY_AI);
        assertFalse(reactor.cronSubscribed());

        // Proposing or withdrawing while frozen reverts on Base Sepolia.
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.prank(actor);
        vm.expectRevert(SynapseGuardVault.VaultIsFrozen.selector);
        vault.proposeIntent(recipient, address(token), 1 ether, 0, 60, bytes32(0));

        vm.expectRevert(SynapseGuardVault.VaultIsFrozen.selector);
        vault.withdrawVaultLiquidity(address(token), owner, 1 ether);

        // Governance calls unfreezeVault() -> emits VaultUnfrozen -> Lasna Reactor dispatches Unichain unfreeze!
        vm.recordLogs();
        vault.unfreezeVault();
        assertFalse(vault.emergencyFrozen());
        (, Vm.Log memory unfrozenLog) = _findEventLog(
            vm.getRecordedLogs(),
            address(vault),
            ISynapseEvents.VaultUnfrozen.selector
        );

        vm.chainId(LASNA_CHAIN_ID);
        uint256 cbBefore = mockSystem.queuedCallbackCount();
        mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, unfrozenLog));
        assertEq(mockSystem.queuedCallbackCount(), cbBefore + 1);

        vm.chainId(UNICHAIN_SEPOLIA_CHAIN_ID);
        (bool okUnfreeze,) = mockSystem.deliverCallbackAt(cbBefore, unichainProxy);
        assertTrue(okUnfreeze);

        assertFalse(sentinel.emergencyLocked());
        assertFalse(sentinel.frozenActors(actor));
    }

    function test_SentinelDuplicateFreezeIgnoredAndOwnerClearActor() public {
        vm.chainId(UNICHAIN_SEPOLIA_CHAIN_ID);
        bytes memory payload = abi.encodeWithSignature(
            "onCrossChainFreeze(address,uint256,address,uint16,bytes32)",
            address(0),
            1,
            actor,
            9000,
            keccak256("m1")
        );
        (bool ok1,) = unichainProxy.deliverCallback(address(sentinel), address(reactor), payload);
        assertTrue(ok1);
        assertEq(sentinel.lockEpoch(), 1);

        // Second freeze for already locked sentinel + actor emits FreezeIgnored and does not bump lockEpoch.
        vm.expectEmit(true, false, false, true, address(sentinel));
        emit SynapseUnichainSentinel.FreezeIgnored(1, true);
        (bool ok2,) = unichainProxy.deliverCallback(address(sentinel), address(reactor), payload);
        assertTrue(ok2);
        assertEq(sentinel.lockEpoch(), 1);

        address otherActor = makeAddr("otherFrozen");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseUnichainSentinel.NotOwner.selector, stranger));
        sentinel.clearActor(otherActor);

        bytes memory payload2 = abi.encodeWithSignature(
            "onCrossChainFreeze(address,uint256,address,uint16,bytes32)",
            address(0),
            2,
            otherActor,
            9100,
            keccak256("m2")
        );
        (bool ok3,) = unichainProxy.deliverCallback(address(sentinel), address(reactor), payload2);
        assertTrue(ok3);
        assertTrue(sentinel.frozenActors(otherActor));
        sentinel.clearActor(otherActor);
        assertFalse(sentinel.frozenActors(otherActor));
    }

    // -------------------------------------------------------------------------
    // 5. On-Chain Guardrails, Desync Prevention, Security & Replay Attacks
    // -------------------------------------------------------------------------

    function test_CallbackGuardrails_RejectOverCapWithoutRevertingOrDesyncing() public {
        // Set cap high to allow proposal, then tighten cap while intent awaits AI (adversarial policy update).
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            300 ether,
            100,
            120,
            keccak256("cap-race")
        );

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vault.setPolicy(100 ether, 20, 3600);

        bytes32 digestModel = keccak256("gemini-approve-before-cap-drop");
        _submitVerdictAndCompleteRoundTrip(
            intentId,
            SynapseTypes.DECISION_APPROVE,
            1200,
            uint64(block.timestamp + 60),
            digestModel
        );

        // Vault rejected cleanly WITHOUT revert, zero payout, and Lasna synced SETTLED!
        assertEq(token.balanceOf(recipient), 0);
        assertEq(vault.vaultLiquidity(address(token)), 1_000 ether);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.REJECTED_GUARDRAIL));
        assertEq(reactor.getTrackedIntent(intentId).outcome, SynapseTypes.OUTCOME_REJECTED_GUARDRAIL);
        assertEq(uint8(reactor.getTrackedIntent(intentId).state), uint8(SynapseReactor.ReactorState.SETTLED));
        assertFalse(reactor.cronSubscribed());
    }

    function test_CallbackGuardrails_ConcurrentOverdraftProtection() public {
        // Vault holds 1_000 ether. Propose two 600 ether intents while max cap allows 600 ether.
        vault.setPolicy(600 ether, 20, 3600);

        uint256 id1 = _proposeOnBaseAndRelayToLasna(actor, recipient, address(token), 600 ether, 50, 120, keccak256("i1"));
        uint256 id2 = _proposeOnBaseAndRelayToLasna(actor, recipient, address(token), 600 ether, 50, 120, keccak256("i2"));

        assertTrue(reactor.cronSubscribed());
        assertEq(reactor.getActiveIntentIds().length, 2);

        _submitVerdictAndCompleteRoundTrip(
            id1,
            SynapseTypes.DECISION_APPROVE,
            1000,
            uint64(block.timestamp + 60),
            keccak256("ok1")
        );
        assertEq(token.balanceOf(recipient), 600 ether);
        assertEq(vault.vaultLiquidity(address(token)), 400 ether);
        assertTrue(reactor.cronSubscribed()); // Intent 2 still active -> Cron10 remains active!

        _submitVerdictAndCompleteRoundTrip(
            id2,
            SynapseTypes.DECISION_APPROVE,
            1000,
            uint64(block.timestamp + 60),
            keccak256("ok2")
        );
        // Second intent cleanly caught by INSUFFICIENT_VAULT_LIQUIDITY guardrail without overdraft or revert!
        assertEq(token.balanceOf(recipient), 600 ether);
        assertEq(uint8(vault.getIntent(id2).status), uint8(SynapseGuardVault.VaultIntentStatus.REJECTED_GUARDRAIL));
        assertEq(reactor.getTrackedIntent(id2).outcome, SynapseTypes.OUTCOME_REJECTED_GUARDRAIL);
        assertFalse(reactor.cronSubscribed());
    }

    function test_Security_ProxyAndCallbackSenderEnforcement() public {
        bytes memory spoofPayload = abi.encodeWithSignature(
            "onAIVerdictCallback(address,uint256,uint8,uint16,uint64,bytes32,bytes)",
            address(reactor),
            1,
            SynapseTypes.DECISION_APPROVE,
            0,
            uint64(block.timestamp + 60),
            bytes32(0),
            new bytes(65)
        );

        // Direct call from attacker bypassing Callback Proxy reverts with NotAuthorized.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(baseProxy)));
        (bool directOk,) = address(vault).call(spoofPayload);
        assertTrue(directOk); // expectRevert caught inside call expectations

        // Call via Base Callback Proxy, but Reactive sender overwritten with wrong address -> reverts CallbackNotAuthorized.
        vm.prank(address(baseProxy));
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, address(reactor))
        );
        vault.onAIVerdictCallback(stranger, 1, SynapseTypes.DECISION_APPROVE, 0, uint64(block.timestamp + 60), bytes32(0), "");

        // Sentinel checks too.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(unichainProxy)));
        sentinel.onCrossChainFreeze(address(reactor), 1, actor, 9999, bytes32(0));

        vm.prank(address(unichainProxy));
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, address(reactor))
        );
        sentinel.onCrossChainUnfreeze(stranger, 1, actor);
    }

    function test_Security_SignatureDomainSeparationAndForgedSigHandling() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            50 ether,
            100,
            120,
            keccak256("sig-test")
        );
        uint64 expiryTs = uint64(block.timestamp + 60);
        bytes32 modelDigest = keccak256("model");

        // 1. Wrong private key rejected on Lasna Reactor.
        bytes memory badKeySig = _signVerdict(
            ATTACKER_PK,
            BASE_SEPOLIA_CHAIN_ID,
            address(vault),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            500,
            expiryTs,
            modelDigest
        );
        vm.chainId(LASNA_CHAIN_ID);
        vm.expectRevert(SynapseReactor.InvalidAISignature.selector);
        reactor.submitAIVerdict(intentId, SynapseTypes.DECISION_APPROVE, 500, expiryTs, modelDigest, badKeySig);

        // 2. Wrong chainId replay (e.g. Unichain instead of Base Sepolia) rejected on Lasna Reactor.
        bytes memory wrongChainSig = _signVerdict(
            AI_SIGNER_PK,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(vault),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            500,
            expiryTs,
            modelDigest
        );
        vm.expectRevert(SynapseReactor.InvalidAISignature.selector);
        reactor.submitAIVerdict(intentId, SynapseTypes.DECISION_APPROVE, 500, expiryTs, modelDigest, wrongChainSig);

        // 3. Wrong vault address replay rejected on Lasna Reactor.
        bytes memory wrongVaultSig = _signVerdict(
            AI_SIGNER_PK,
            BASE_SEPOLIA_CHAIN_ID,
            makeAddr("otherVault"),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            500,
            expiryTs,
            modelDigest
        );
        vm.expectRevert(SynapseReactor.InvalidAISignature.selector);
        reactor.submitAIVerdict(intentId, SynapseTypes.DECISION_APPROVE, 500, expiryTs, modelDigest, wrongVaultSig);

        // 4. Even if forged signature somehow reached Base Vault via proxy (e.g. signer rotated on Lasna only),
        // Base Vault refuses execution with INVALID_AI_SIGNATURE and syncs Lasna!
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.recordLogs();
        bytes memory forgeVaultPayload = abi.encodeWithSignature(
            "onAIVerdictCallback(address,uint256,uint8,uint16,uint64,bytes32,bytes)",
            address(0),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            500,
            expiryTs,
            modelDigest,
            badKeySig
        );
        (bool ok,) = baseProxy.deliverCallback(address(vault), address(reactor), forgeVaultPayload);
        assertTrue(ok);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.REJECTED_GUARDRAIL));

        (, Vm.Log memory settledLog) = _findEventLog(
            vm.getRecordedLogs(),
            address(vault),
            ISynapseEvents.IntentSettled.selector
        );
        vm.chainId(LASNA_CHAIN_ID);
        mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, settledLog));
        assertEq(reactor.getTrackedIntent(intentId).outcome, SynapseTypes.OUTCOME_REJECTED_GUARDRAIL);
        assertFalse(reactor.cronSubscribed());
    }

    function test_Security_DuplicateCallbackIsIdempotent() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            100 ether,
            50,
            120,
            keccak256("dup-cb")
        );
        uint64 expiryTs = uint64(block.timestamp + 60);
        bytes32 digestModel = keccak256("dup-model");
        bytes memory sig = _signVerdict(
            AI_SIGNER_PK,
            BASE_SEPOLIA_CHAIN_ID,
            address(vault),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            400,
            expiryTs,
            digestModel
        );

        _submitVerdictAndCompleteRoundTrip(intentId, SynapseTypes.DECISION_APPROVE, 400, expiryTs, digestModel);
        assertEq(token.balanceOf(recipient), 100 ether);

        // Delivering duplicate verdict callback emits CallbackIgnored and does NOT pay twice!
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        bytes memory rawPayload = abi.encodeWithSignature(
            "onAIVerdictCallback(address,uint256,uint8,uint16,uint64,bytes32,bytes)",
            address(0),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            400,
            expiryTs,
            digestModel,
            sig
        );
        vm.expectEmit(true, false, false, true, address(vault));
        emit SynapseGuardVault.CallbackIgnored(intentId, SynapseGuardVault.VaultIntentStatus.EXECUTED);
        (bool ok2,) = baseProxy.deliverCallback(address(vault), address(reactor), rawPayload);
        assertTrue(ok2);
        assertEq(token.balanceOf(recipient), 100 ether);
    }

    // -------------------------------------------------------------------------
    // 6. Autonomous AI-Offline Watchdog (Cron10 Lazy Subscribe + Timeout Fallback)
    // -------------------------------------------------------------------------

    function test_CronWatchdog_AutonomousTimeoutFallbackWhenAIOffline() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            75 ether,
            300,
            25, // 25 seconds TTL (compatible with Base Sepolia 200ms blocks via timestamp)
            keccak256("ai-offline-case")
        );

        assertTrue(reactor.cronSubscribed());
        assertEq(reactor.getActiveIntentIds().length, 1);

        // Cron fires BEFORE deadline -> nothing dispatched yet, Cron stays active.
        vm.warp(block.timestamp + 15);
        vm.chainId(LASNA_CHAIN_ID);
        uint256 cbBeforeEarly = mockSystem.queuedCallbackCount();
        mockSystem.triggerReact(
            address(reactor),
            IReactive.LogRecord({
                chainId: LASNA_CHAIN_ID,
                contractAddress: LEGACY_SYSTEM_ADDR,
                topic0: CRON10_TOPIC_0,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: abi.encode(block.number),
                blockNumber: block.number,
                opCode: 1,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
        assertEq(mockSystem.queuedCallbackCount(), cbBeforeEarly);
        assertEq(
            uint8(reactor.getTrackedIntent(intentId).state),
            uint8(SynapseReactor.ReactorState.PENDING_AI)
        );

        // Warp past TTL deadline (simulate Gemini AI worker completely offline) and fire Cron10!
        vm.warp(block.timestamp + 15); // total +30s > 25s
        mockSystem.triggerReact(
            address(reactor),
            IReactive.LogRecord({
                chainId: LASNA_CHAIN_ID,
                contractAddress: LEGACY_SYSTEM_ADDR,
                topic0: CRON10_TOPIC_0,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: abi.encode(block.number + 10),
                blockNumber: block.number + 10,
                opCode: 1,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
        assertEq(mockSystem.queuedCallbackCount(), cbBeforeEarly + 1);
        assertEq(
            uint8(reactor.getTrackedIntent(intentId).state),
            uint8(SynapseReactor.ReactorState.TIMED_OUT_DISPATCHED)
        );

        // Callback executes onTimeoutFallbackCallback on Base Sepolia and syncs back to Lasna!
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.recordLogs();
        (bool ok,) = mockSystem.deliverCallbackAt(cbBeforeEarly, baseProxy);
        assertTrue(ok);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.TIMED_OUT));
        assertEq(token.balanceOf(recipient), 0);

        (, Vm.Log memory settledLog) = _findEventLog(
            vm.getRecordedLogs(),
            address(vault),
            ISynapseEvents.IntentSettled.selector
        );
        vm.chainId(LASNA_CHAIN_ID);
        mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, settledLog));

        assertEq(
            uint8(reactor.getTrackedIntent(intentId).state),
            uint8(SynapseReactor.ReactorState.SETTLED)
        );
        assertEq(reactor.getTrackedIntent(intentId).outcome, SynapseTypes.OUTCOME_TIMED_OUT);
        assertFalse(reactor.cronSubscribed());
        assertEq(mockSystem.activeSubscriptionCount(address(reactor)), 3); // 6-arg Cron10 unsubscribed cleanly!
    }

    function test_SelfRescueCancelExpiredIntentAndReverts() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            20 ether,
            0,
            25,
            bytes32(0)
        );

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.NotIntentActor.selector, stranger, actor));
        vault.cancelExpiredIntent(intentId);

        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(
                SynapseGuardVault.IntentStillActive.selector,
                block.timestamp + 25,
                block.timestamp
            )
        );
        vault.cancelExpiredIntent(intentId);

        vm.warp(block.timestamp + 26);
        vm.recordLogs();
        vm.prank(actor);
        vault.cancelExpiredIntent(intentId);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.CANCELLED));

        (, Vm.Log memory settledLog) = _findEventLog(
            vm.getRecordedLogs(),
            address(vault),
            ISynapseEvents.IntentSettled.selector
        );
        vm.chainId(LASNA_CHAIN_ID);
        mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, settledLog));
        assertEq(reactor.getActiveIntentIds().length, 0);
        assertFalse(reactor.cronSubscribed());
    }

    function test_Guardrail_ExpiredTimestampVerdictInCallback() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            80 ether,
            50,
            30,
            keccak256("expiry-cb")
        );
        uint64 expiryTs = uint64(block.timestamp + 25);
        bytes32 modelDigest = keccak256("expiry-model");
        bytes memory sig = _signVerdict(
            AI_SIGNER_PK,
            BASE_SEPOLIA_CHAIN_ID,
            address(vault),
            intentId,
            SynapseTypes.DECISION_APPROVE,
            200,
            expiryTs,
            modelDigest
        );

        vm.chainId(LASNA_CHAIN_ID);
        uint256 cbIdx = mockSystem.queuedCallbackCount();
        reactor.submitAIVerdict(intentId, SynapseTypes.DECISION_APPROVE, 200, expiryTs, modelDigest, sig);

        // Bridge delay pushes timestamp past expiryTs BEFORE Base Proxy delivers callback.
        vm.warp(block.timestamp + 26);
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.recordLogs();
        (bool ok,) = mockSystem.deliverCallbackAt(cbIdx, baseProxy);
        assertTrue(ok);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.TIMED_OUT));

        (, Vm.Log memory settledLog) = _findEventLog(
            vm.getRecordedLogs(),
            address(vault),
            ISynapseEvents.IntentSettled.selector
        );
        vm.chainId(LASNA_CHAIN_ID);
        mockSystem.triggerReact(address(reactor), _toLogRecord(BASE_SEPOLIA_CHAIN_ID, settledLog));
        assertEq(reactor.getTrackedIntent(intentId).outcome, SynapseTypes.OUTCOME_TIMED_OUT);
        assertFalse(reactor.cronSubscribed());
    }

    function test_Guardrail_VaultAlreadyFrozenRejectsPendingApprove() public {
        uint256 id1 = _proposeOnBaseAndRelayToLasna(actor, recipient, address(token), 50 ether, 9900, 120, keccak256("f1"));
        uint256 id2 = _proposeOnBaseAndRelayToLasna(actor, recipient, address(token), 50 ether, 10, 120, keccak256("f2"));

        // Intent 1 triggers emergency freeze.
        _submitVerdictAndCompleteRoundTrip(
            id1,
            SynapseTypes.DECISION_FREEZE_EMERGENCY,
            9900,
            uint64(block.timestamp + 60),
            keccak256("freeze1")
        );
        assertTrue(vault.emergencyFrozen());

        // Intent 2 arrives with APPROVE -> Base Vault blocks execution via VAULT_ALREADY_FROZEN and syncs Lasna.
        _submitVerdictAndCompleteRoundTrip(
            id2,
            SynapseTypes.DECISION_APPROVE,
            100,
            uint64(block.timestamp + 60),
            keccak256("approve2")
        );
        assertEq(token.balanceOf(recipient), 0);
        assertEq(uint8(vault.getIntent(id2).status), uint8(SynapseGuardVault.VaultIntentStatus.REJECTED_GUARDRAIL));
        assertEq(reactor.getTrackedIntent(id2).outcome, SynapseTypes.OUTCOME_REJECTED_GUARDRAIL);
        assertFalse(reactor.cronSubscribed());
    }

    function test_Guardrail_LateTimeoutCallbackIgnoredAfterExecuted() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            50 ether,
            50,
            120,
            keccak256("late-timeout")
        );
        _submitVerdictAndCompleteRoundTrip(
            intentId,
            SynapseTypes.DECISION_APPROVE,
            300,
            uint64(block.timestamp + 60),
            keccak256("ok")
        );

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        bytes memory timeoutPayload = abi.encodeWithSignature("onTimeoutFallbackCallback(address,uint256)", address(0), intentId);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SynapseGuardVault.CallbackIgnored(intentId, SynapseGuardVault.VaultIntentStatus.EXECUTED);
        (bool ok,) = baseProxy.deliverCallback(address(vault), address(reactor), timeoutPayload);
        assertTrue(ok);
        assertEq(uint8(vault.getIntent(intentId).status), uint8(SynapseGuardVault.VaultIntentStatus.EXECUTED));
    }

    function test_Vault_ProposeAndUnfreezeValidationReverts() public {
        vm.expectRevert(SynapseGuardVault.VaultNotFrozen.selector);
        vault.unfreezeVault();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.NotOwner.selector, stranger));
        vault.unfreezeVault();

        vm.prank(actor);
        vm.expectRevert(SynapseGuardVault.ZeroAddress.selector);
        vault.proposeIntent(address(0), address(token), 1 ether, 0, 60, bytes32(0));

        vm.prank(actor);
        vm.expectRevert(SynapseGuardVault.InvalidAmount.selector);
        vault.proposeIntent(recipient, address(token), 0, 0, 60, bytes32(0));

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.InvalidTTL.selector, 19));
        vault.proposeIntent(recipient, address(token), 1 ether, 0, 19, bytes32(0));

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(SynapseGuardVault.InvalidTTL.selector, 3601));
        vault.proposeIntent(recipient, address(token), 1 ether, 0, 3601, bytes32(0));

        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(SynapseGuardVault.InsufficientVaultLiquidity.selector, 2_000 ether, 1_000 ether)
        );
        vault.proposeIntent(recipient, address(token), 2_000 ether, 0, 60, bytes32(0));
    }

    function test_Reactor_SubmitVerdictValidationReverts() public {
        uint256 intentId = _proposeOnBaseAndRelayToLasna(
            actor,
            recipient,
            address(token),
            20 ether,
            50,
            60,
            keccak256("reactor-reverts")
        );
        bytes memory dummySig = new bytes(65);
        vm.chainId(LASNA_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(SynapseReactor.InvalidDecision.selector, 3));
        reactor.submitAIVerdict(intentId, 3, 100, uint64(block.timestamp + 30), bytes32(0), dummySig);

        vm.expectRevert(
            abi.encodeWithSelector(SynapseReactor.NotPendingAI.selector, 999, SynapseReactor.ReactorState.NONE)
        );
        reactor.submitAIVerdict(999, SynapseTypes.DECISION_APPROVE, 100, uint64(block.timestamp + 30), bytes32(0), dummySig);

        uint64 pastExpiry = uint64(block.timestamp - 1);
        vm.expectRevert(
            abi.encodeWithSelector(SynapseReactor.ExpiredVerdict.selector, pastExpiry, block.timestamp)
        );
        reactor.submitAIVerdict(intentId, SynapseTypes.DECISION_APPROVE, 100, pastExpiry, bytes32(0), dummySig);
    }

    // -------------------------------------------------------------------------
    // 7. Fuzz Invariant Tests
    // -------------------------------------------------------------------------

    function testFuzz_SignatureBindingAndVaultLiquidityConservation(
        uint256 rawAmount_,
        uint16 riskScore_,
        uint8 rawDecision_,
        uint256 fakeChainId_
    ) public {
        uint256 amount = bound(rawAmount_, 1 wei, MAX_SINGLE_CAP);
        uint8 decision = uint8(bound(rawDecision_, 0, 2));
        uint256 liqBefore = vault.vaultLiquidity(address(token));

        uint256 intentId;
        {
            bytes32 ctx = keccak256(abi.encode(amount, riskScore_));
            intentId = _proposeOnBaseAndRelayToLasna(actor, recipient, address(token), amount, 123, 60, ctx);
        }

        uint64 expiryTs = uint64(block.timestamp + 45);
        bytes32 digestModel = keccak256(abi.encode(decision, riskScore_));
        _assertWrongChainSignatureReverts(intentId, decision, riskScore_, expiryTs, digestModel, fakeChainId_);

        _submitVerdictAndCompleteRoundTrip(intentId, decision, riskScore_, expiryTs, digestModel);

        uint256 expectedDelta = (decision == SynapseTypes.DECISION_APPROVE) ? amount : 0;
        assertEq(vault.vaultLiquidity(address(token)), liqBefore - expectedDelta);
        assertEq(token.balanceOf(address(vault)), liqBefore - expectedDelta);
        assertEq(token.balanceOf(recipient), expectedDelta);
        assertFalse(reactor.cronSubscribed());
    }

    function _assertWrongChainSignatureReverts(
        uint256 intentId_,
        uint8 decision_,
        uint16 riskScore_,
        uint64 expiryTs_,
        bytes32 digestModel_,
        uint256 rawFakeChainId_
    ) internal {
        uint256 fakeChainId = bound(rawFakeChainId_, 1, 1_000_000_000);
        if (fakeChainId == BASE_SEPOLIA_CHAIN_ID) {
            fakeChainId = BASE_SEPOLIA_CHAIN_ID + 1;
        }
        bytes memory crossChainSig = _signVerdict(
            AI_SIGNER_PK,
            fakeChainId,
            address(vault),
            intentId_,
            decision_,
            riskScore_,
            expiryTs_,
            digestModel_
        );
        vm.chainId(LASNA_CHAIN_ID);
        vm.expectRevert(SynapseReactor.InvalidAISignature.selector);
        reactor.submitAIVerdict(intentId_, decision_, riskScore_, expiryTs_, digestModel_, crossChainSig);
    }

    function testFuzz_ConcurrentIntentsLazyCronAndStateSyncInvariant(uint8 rawCount_, uint16 settleMask_) public {
        uint256 n = bound(rawCount_, 1, 10);
        uint256[] memory ids = new uint256[](n);

        // Propose n concurrent small intents -> Cron10 must become active once on intent #1 and subscribe only once.
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = _proposeOnBaseAndRelayToLasna(
                actor,
                recipient,
                address(token),
                10 ether,
                uint16(i * 100),
                120,
                keccak256(abi.encode("fuzz-concurrent", i))
            );
            assertTrue(reactor.cronSubscribed());
            assertEq(reactor.getActiveIntentIds().length, i + 1);
            assertEq(reactor.cronSubscribed(), reactor.getActiveIntentIds().length > 0);
        }

        // Settle all n intents with varied decisions (skip/warp on some? settle in reverse/mixed order).
        for (uint256 k = 0; k < n; ++k) {
            uint256 idx = (k % 2 == 0) ? k : (n - 1 - k);
            // Guarantee unique permutation when k sweeps both ends without collision: iterate cleanly or swap indices.
            idx = n - 1 - k;
            uint8 dec = ((settleMask_ >> (k % 16)) & 1 == 0)
                ? SynapseTypes.DECISION_APPROVE
                : SynapseTypes.DECISION_REJECT;

            _submitVerdictAndCompleteRoundTrip(
                ids[idx],
                dec,
                500,
                uint64(block.timestamp + 60),
                keccak256(abi.encode("fuzz-done", idx))
            );

            bool shouldCronBeActive = (n - 1 - k) > 0;
            assertEq(reactor.getActiveIntentIds().length, n - 1 - k);
            assertEq(reactor.cronSubscribed(), shouldCronBeActive);
            assertEq(
                mockSystem.isSubscribed(
                    address(reactor),
                    LASNA_CHAIN_ID,
                    LEGACY_SYSTEM_ADDR,
                    CRON10_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                ),
                shouldCronBeActive
            );
        }
    }

    function testFuzz_ReactorReactNeverRevertsOnMalformedLogs(
        uint256 cid_,
        address contract_,
        uint256 t0_,
        uint256 t1_,
        uint256 t2_,
        uint256 t3_,
        bytes calldata data_
    ) public {
        // Note: malformed ABI lengths inside `LogRecord.data` for matching topic0 shouldn't revert normal random logs;
        // if an arbitrary log happens to hit _TOPIC_INTENT_PROPOSED with empty `data`, ensure it's skipped unless properly encoded.
        if (t0_ == uint256(ISynapseEvents.IntentProposed.selector) || t0_ == uint256(ISynapseEvents.IntentSettled.selector)) {
            if (contract_ == address(vault) && cid_ == BASE_SEPOLIA_CHAIN_ID && data_.length < 128) {
                return;
            }
        }

        vm.chainId(LASNA_CHAIN_ID);
        mockSystem.triggerReact(
            address(reactor),
            IReactive.LogRecord({
                chainId: cid_,
                contractAddress: contract_,
                topic0: t0_,
                topic1: t1_,
                topic2: t2_,
                topic3: t3_,
                data: data_,
                blockNumber: block.number,
                opCode: 4,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
    }
}
