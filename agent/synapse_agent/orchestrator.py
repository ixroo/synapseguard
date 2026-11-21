"""Multi-chain Reactive Omni orchestrator bridging Base Sepolia, Lasna, Unichain Sepolia, and Gemini AI."""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from eth_account import Account
from web3 import Web3
from web3.contract import Contract

from synapse_agent.abi import load_contract_abi
from synapse_agent.analyzer import AnalyzedVerdict, IntentTelemetry, evaluate_intent_with_gemini
from synapse_agent.config import (
    BASE_SEPOLIA_CHAIN_ID,
    DECISION_FREEZE_EMERGENCY,
    OUTCOME_NAMES,
    DeploymentConfig,
    RuntimeSettings,
)
from synapse_agent.signer import sign_verdict


ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


@dataclass
class IntentExecutionTrace:
    intent_id: int
    scenario: str
    origin_propose_tx: str
    lasna_submit_tx: str
    base_settlement_tx: str | None
    unichain_freeze_tx: str | None
    lasna_sync_tx: str | None
    decision: str
    risk_score_bps: int
    confidence: float
    rationale: str
    engine: str
    model_digest_hex: str
    vault_outcome_code: int
    vault_outcome_name: str
    vault_executed: bool
    lasna_synced: bool
    unichain_locked_after: bool
    gemini_latency_ms: float
    lasna_pickup_latency_ms: float | None
    total_e2e_latency_ms: float | None
    created_utc: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class SynapseOrchestrator:
    """Watches Reactive Lasna & Base Sepolia, runs Gemini risk scoring, signs & dispatches verdicts."""

    def __init__(self, settings: RuntimeSettings, deploy: DeploymentConfig) -> None:
        self.settings = settings
        self.deploy = deploy

        self.w3_base = Web3(Web3.HTTPProvider(settings.base_rpc_url, request_kwargs={"timeout": 30}))
        self.w3_lasna = Web3(Web3.HTTPProvider(settings.lasna_rpc_url, request_kwargs={"timeout": 30}))
        self.w3_uni = Web3(Web3.HTTPProvider(settings.unichain_rpc_url, request_kwargs={"timeout": 30}))

        self.vault: Contract = self.w3_base.eth.contract(
            address=Web3.to_checksum_address(deploy.synapse_guard_vault),
            abi=load_contract_abi("SynapseGuardVault"),
        )
        self.reactor: Contract = self.w3_lasna.eth.contract(
            address=Web3.to_checksum_address(deploy.synapse_reactor),
            abi=load_contract_abi("SynapseReactor"),
        )
        self.sentinel: Contract = self.w3_uni.eth.contract(
            address=Web3.to_checksum_address(deploy.synapse_unichain_sentinel),
            abi=load_contract_abi("SynapseUnichainSentinel"),
        )
        self.demo_token: Contract = self.w3_base.eth.contract(
            address=Web3.to_checksum_address(deploy.demo_token),
            abi=load_contract_abi("DemoToken"),
        )

    def snapshot_chain_state(self) -> dict[str, Any]:
        """Collect live telemetry across Base Sepolia, Lasna, and Unichain Sepolia."""
        reactor_addr = Web3.to_checksum_address(self.deploy.synapse_reactor)
        vault_addr = Web3.to_checksum_address(self.deploy.synapse_guard_vault)
        sentinel_addr = Web3.to_checksum_address(self.deploy.synapse_unichain_sentinel)
        tok_addr = Web3.to_checksum_address(self.deploy.demo_token)

        active_ids = self.reactor.functions.getActiveIntentIds().call()
        return {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "base_sepolia": {
                "block": self.w3_base.eth.block_number,
                "vault": vault_addr,
                "emergency_frozen": self.vault.functions.emergencyFrozen().call(),
                "freeze_epoch": self.vault.functions.freezeEpoch().call(),
                "next_intent_id": self.vault.functions.nextIntentId().call(),
                "max_single_intent_wei": str(self.vault.functions.maxSingleIntentAmount().call()),
                "eth_liquidity_wei": str(self.vault.functions.vaultLiquidity(ZERO_ADDRESS).call()),
                "token_liquidity_wei": str(self.vault.functions.vaultLiquidity(tok_addr).call()),
            },
            "lasna": {
                "block": self.w3_lasna.eth.block_number,
                "reactor": reactor_addr,
                "configured": self.reactor.functions.configured().call(),
                "cron_subscribed": self.reactor.functions.cronSubscribed().call(),
                "active_intent_ids": list(active_ids),
                "balance_wei": str(self.w3_lasna.eth.get_balance(reactor_addr)),
            },
            "unichain_sepolia": {
                "block": self.w3_uni.eth.block_number,
                "sentinel": sentinel_addr,
                "emergency_locked": self.sentinel.functions.emergencyLocked().call(),
                "lock_epoch": self.sentinel.functions.lockEpoch().call(),
                "last_risk_score": self.sentinel.functions.lastRiskScore().call(),
            },
        }

    def fetch_intent_telemetry(self, intent_id: int) -> IntentTelemetry:
        """Read canonical intent + vault liquidity state straight from Base Sepolia."""
        raw = self.vault.functions.getIntent(intent_id).call()
        actor, recipient, token, amount, anomaly_bps, _created_at, deadline_ts, ctx_hash, _status = raw
        liq = self.vault.functions.vaultLiquidity(token).call()
        max_cap = self.vault.functions.maxSingleIntentAmount().call()
        frozen = self.vault.functions.emergencyFrozen().call()
        now_ts = int(time.time())
        return IntentTelemetry(
            intent_id=intent_id,
            actor=actor,
            recipient=recipient,
            token=token,
            is_native_eth=(token.lower() == ZERO_ADDRESS.lower()),
            amount_wei=int(amount),
            vault_liquidity_wei=int(liq),
            max_single_intent_wei=int(max_cap),
            anomaly_hint_bps=int(anomaly_bps),
            ttl_remaining_sec=int(deadline_ts) - now_ts,
            emergency_frozen=bool(frozen),
            context_hash_hex="0x" + bytes(ctx_hash).hex(),
        )

    def wait_for_lasna_pending_intent(self, intent_id: int, timeout_sec: float = 90.0) -> float:
        """Poll Lasna Reactor until React() ingests IntentProposed -> PENDING_AI (returns pickup latency ms)."""
        t0 = time.perf_counter()
        deadline = t0 + timeout_sec
        while time.perf_counter() < deadline:
            tracked = self.reactor.functions.getTrackedIntent(intent_id).call()
            state_code = int(tracked[6])
            if state_code >= 1:  # PENDING_AI or beyond
                return (time.perf_counter() - t0) * 1000.0
            time.sleep(0.6)
        raise TimeoutError(f"Timed out waiting for Lasna Reactor to ingest intent {intent_id}")

    def sign_and_submit_verdict(
        self,
        intent_id: int,
        verdict: AnalyzedVerdict,
        expiry_window_sec: int = 300,
    ) -> str:
        """Sign canonical EIP-191 digest with AI signer key and broadcast submitAIVerdict on Lasna."""
        if not self.settings.ai_signer_private_key:
            raise RuntimeError("AI_SIGNER_PRIVATE_KEY is missing from environment")
        if not self.settings.submitter_private_key:
            raise RuntimeError("Submitter private key is missing from environment")

        expiry_ts = int(time.time()) + int(expiry_window_sec)
        sig = sign_verdict(
            private_key=self.settings.ai_signer_private_key,
            dest_chain_id=BASE_SEPOLIA_CHAIN_ID,
            vault_address=self.deploy.synapse_guard_vault,
            intent_id=intent_id,
            decision=verdict.decision,
            risk_score_bps=verdict.risk_score_bps,
            expiry_ts=expiry_ts,
            model_digest=verdict.model_digest,
        )
        return self._send_tx(
            self.w3_lasna,
            self.settings.submitter_private_key,
            self.reactor.functions.submitAIVerdict(
                intent_id,
                verdict.decision,
                verdict.risk_score_bps,
                expiry_ts,
                verdict.model_digest,
                sig,
            ),
            gas=700_000,
        )

    def wait_for_full_loop_settlement(
        self,
        intent_id: int,
        expect_unichain_freeze: bool,
        base_from_block: int,
        lasna_from_block: int,
        uni_from_block: int,
        timeout_sec: float = 150.0,
    ) -> dict[str, Any]:
        """Wait for Base IntentSettled, optional Unichain Freeze, AND final Lasna ReactorStateSynced."""
        deadline = time.perf_counter() + timeout_sec
        base_tx: str | None = None
        uni_tx: str | None = None
        lasna_sync_tx: str | None = None
        outcome_code = 0
        executed = False

        while time.perf_counter() < deadline:
            cur_base = self.w3_base.eth.block_number
            base_win_from = max(base_from_block, cur_base - 900)
            if base_tx is None:
                logs = self.vault.events.IntentSettled().get_logs(
                    from_block=base_win_from,
                    to_block=cur_base,
                    argument_filters={"intentId": intent_id},
                )
                if logs:
                    ev = logs[-1]
                    base_tx = ev["transactionHash"].hex()
                    outcome_code = int(ev["args"]["outcome"])
                    executed = bool(ev["args"]["executed"])

            if expect_unichain_freeze and uni_tx is None:
                cur_uni = self.w3_uni.eth.block_number
                uni_win_from = max(uni_from_block, cur_uni - 900)
                ulogs = self.sentinel.events.UnichainSentinelFrozen().get_logs(
                    from_block=uni_win_from,
                    to_block=cur_uni,
                    argument_filters={"intentId": intent_id},
                )
                if ulogs:
                    uni_tx = ulogs[-1]["transactionHash"].hex()

            if lasna_sync_tx is None:
                tracked = self.reactor.functions.getTrackedIntent(intent_id).call()
                if int(tracked[6]) == 3:  # ReactorState.SETTLED
                    cur_lasna = self.w3_lasna.eth.block_number
                    lasna_win_from = max(lasna_from_block, cur_lasna - 900)
                    slogs = self.reactor.events.ReactorStateSynced().get_logs(
                        from_block=lasna_win_from,
                        to_block=cur_lasna,
                        argument_filters={"intentId": intent_id},
                    )
                    if slogs:
                        lasna_sync_tx = slogs[-1]["transactionHash"].hex()
                        if outcome_code == 0:
                            outcome_code = int(slogs[-1]["args"]["outcome"])
                            executed = bool(slogs[-1]["args"]["executed"])

            uni_done = (not expect_unichain_freeze) or (uni_tx is not None)
            if base_tx is not None and lasna_sync_tx is not None and uni_done:
                return {
                    "base_settlement_tx": _ensure_0x(base_tx),
                    "unichain_freeze_tx": _ensure_0x(uni_tx) if uni_tx else None,
                    "lasna_sync_tx": _ensure_0x(lasna_sync_tx),
                    "outcome_code": outcome_code,
                    "outcome_name": OUTCOME_NAMES.get(outcome_code, f"UNKNOWN({outcome_code})"),
                    "executed": executed,
                    "lasna_synced": True,
                    "unichain_locked": bool(self.sentinel.functions.emergencyLocked().call()),
                }

            time.sleep(1.0)

        raise TimeoutError(
            f"Settlement incomplete for intent {intent_id}: base={base_tx}, uni={uni_tx}, lasna={lasna_sync_tx}"
        )

    def run_single_live_loop(
        self,
        scenario_name: str,
        recipient: str,
        token: str,
        amount_wei: int,
        anomaly_hint_bps: int,
        ttl_seconds: int = 90,
        allow_heuristic_fallback: bool = False,
    ) -> IntentExecutionTrace:
        """Execute and trace a complete Origin -> Lasna -> Gemini AI -> Destination -> Lasna loop."""
        actor_key = self.settings.submitter_private_key
        if not actor_key:
            raise RuntimeError("Missing deployer/actor private key")

        base_start_blk = self.w3_base.eth.block_number
        lasna_start_blk = self.w3_lasna.eth.block_number
        uni_start_blk = self.w3_uni.eth.block_number

        t_loop_start = time.perf_counter()
        ctx_hash = Web3.keccak(text=f"synapseguard:{scenario_name}:{int(time.time())}")
        propose_tx = self._send_tx(
            self.w3_base,
            actor_key,
            self.vault.functions.proposeIntent(
                Web3.to_checksum_address(recipient),
                Web3.to_checksum_address(token),
                int(amount_wei),
                int(anomaly_hint_bps),
                int(ttl_seconds),
                ctx_hash,
            ),
            gas=300_000,
        )
        receipt = self.w3_base.eth.get_transaction_receipt(propose_tx)
        prop_logs = self.vault.events.IntentProposed().process_receipt(receipt)
        if not prop_logs:
            raise RuntimeError(f"IntentProposed event not emitted in tx {propose_tx}")
        intent_id = int(prop_logs[0]["args"]["intentId"])

        pickup_ms = self.wait_for_lasna_pending_intent(intent_id)
        telemetry = self.fetch_intent_telemetry(intent_id)
        verdict = evaluate_intent_with_gemini(
            telemetry,
            api_key=self.settings.gemini_api_key,
            model_name=self.settings.gemini_model,
            allow_heuristic_fallback=allow_heuristic_fallback,
        )
        lasna_submit_tx = self.sign_and_submit_verdict(intent_id, verdict)

        expect_freeze = verdict.decision == DECISION_FREEZE_EMERGENCY
        settled = self.wait_for_full_loop_settlement(
            intent_id=intent_id,
            expect_unichain_freeze=expect_freeze,
            base_from_block=base_start_blk,
            lasna_from_block=lasna_start_blk,
            uni_from_block=uni_start_blk,
        )
        total_ms = (time.perf_counter() - t_loop_start) * 1000.0

        return IntentExecutionTrace(
            intent_id=intent_id,
            scenario=scenario_name,
            origin_propose_tx=_ensure_0x(propose_tx),
            lasna_submit_tx=_ensure_0x(lasna_submit_tx),
            base_settlement_tx=settled["base_settlement_tx"],
            unichain_freeze_tx=settled["unichain_freeze_tx"],
            lasna_sync_tx=settled["lasna_sync_tx"],
            decision=verdict.decision_name,
            risk_score_bps=verdict.risk_score_bps,
            confidence=verdict.confidence,
            rationale=verdict.rationale,
            engine=verdict.engine,
            model_digest_hex="0x" + verdict.model_digest.hex(),
            vault_outcome_code=settled["outcome_code"],
            vault_outcome_name=settled["outcome_name"],
            vault_executed=settled["executed"],
            lasna_synced=settled["lasna_synced"],
            unichain_locked_after=settled["unichain_locked"],
            gemini_latency_ms=round(verdict.latency_ms, 2),
            lasna_pickup_latency_ms=round(pickup_ms, 2),
            total_e2e_latency_ms=round(total_ms, 2),
            created_utc=datetime.now(timezone.utc).isoformat(),
        )

    def watch_loop(self, poll_interval_sec: float = 2.0, allow_heuristic_fallback: bool = True) -> None:
        """Continuously monitor Reactor.getActiveIntentIds() for PENDING_AI intents and evaluate via Gemini."""
        processed: set[int] = set()
        while True:
            try:
                active_ids = self.reactor.functions.getActiveIntentIds().call()
                for intent_id in active_ids:
                    if intent_id in processed:
                        continue
                    tracked = self.reactor.functions.getTrackedIntent(intent_id).call()
                    if int(tracked[6]) == 1:  # PENDING_AI
                        telemetry = self.fetch_intent_telemetry(intent_id)
                        verdict = evaluate_intent_with_gemini(
                            telemetry,
                            api_key=self.settings.gemini_api_key,
                            model_name=self.settings.gemini_model,
                            allow_heuristic_fallback=allow_heuristic_fallback,
                        )
                        tx_hash = self.sign_and_submit_verdict(intent_id, verdict)
                        processed.add(intent_id)
                        print(
                            f"[SynapseAgent] intent={intent_id} decision={verdict.decision_name} "
                            f"risk={verdict.risk_score_bps}bps engine={verdict.engine} tx={tx_hash}",
                            flush=True,
                        )
            except Exception as exc:  # noqa: BLE001
                print(f"[SynapseAgent] watch error: {exc}", flush=True)
            time.sleep(poll_interval_sec)

    @staticmethod
    def _send_tx(w3: Web3, private_key: str, fn_call: Any, gas: int) -> str:
        acct = Account.from_key(private_key)
        nonce = w3.eth.get_transaction_count(acct.address, "pending")
        gas_price = max(int(w3.eth.gas_price * 1.25), 1_000_000)
        tx = fn_call.build_transaction(
            {
                "from": acct.address,
                "nonce": nonce,
                "gas": gas,
                "gasPrice": gas_price,
                "chainId": w3.eth.chain_id,
            }
        )
        signed = acct.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=90)
        if receipt.status != 1:
            raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")
        return _ensure_0x(tx_hash.hex())


def _ensure_0x(val: str) -> str:
    return val if val.startswith("0x") else "0x" + val


def write_trace_report(out_path: Path, traces: list[IntentExecutionTrace], extra: dict[str, Any] | None = None) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, Any] = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "total_runs": len(traces),
        "runs": [t.to_dict() for t in traces],
    }
    if extra:
        payload.update(extra)
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
