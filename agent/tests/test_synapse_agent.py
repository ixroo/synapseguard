"""Unit, parity, guardrail, and mocked multi-chain tests for synapse_agent."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from eth_account import Account
from web3 import Web3

from synapse_agent.abi import load_contract_abi
from synapse_agent.analyzer import (
    IntentTelemetry,
    deterministic_risk_baseline,
    evaluate_intent_with_gemini,
)
from synapse_agent.cli import _compute_summary
from synapse_agent.config import (
    BASE_SEPOLIA_CHAIN_ID,
    DECISION_APPROVE,
    DECISION_FREEZE_EMERGENCY,
    DECISION_REJECT,
    DeploymentConfig,
)
from synapse_agent.orchestrator import IntentExecutionTrace
from synapse_agent.signer import (
    compute_model_digest,
    compute_verdict_struct_hash,
    recover_verdict_signer,
    sign_verdict,
)


TEST_PK = "0x" + "11" * 32
TEST_ADDR = Account.from_key(TEST_PK).address
VAULT_ADDR = "0x1111111111111111111111111111111111111111"
ACTOR_ADDR = "0x2222222222222222222222222222222222222222"
RECIPIENT_ADDR = "0x3333333333333333333333333333333333333333"
TOKEN_ADDR = "0x4444444444444444444444444444444444444444"


def _make_telemetry(**overrides: object) -> IntentTelemetry:
    base = dict(
        intent_id=1,
        actor=ACTOR_ADDR,
        recipient=RECIPIENT_ADDR,
        token=TOKEN_ADDR,
        is_native_eth=False,
        amount_wei=Web3.to_wei(10, "ether"),
        vault_liquidity_wei=Web3.to_wei(1000, "ether"),
        max_single_intent_wei=Web3.to_wei(500, "ether"),
        anomaly_hint_bps=120,
        ttl_remaining_sec=90,
        emergency_frozen=False,
        context_hash_hex="0x" + "ab" * 32,
    )
    base.update(overrides)
    return IntentTelemetry(**base)  # type: ignore[arg-type]


def test_load_compiled_foundry_abis() -> None:
    for name in ("SynapseGuardVault", "SynapseReactor", "SynapseUnichainSentinel", "DemoToken"):
        abi = load_contract_abi(name)
        assert isinstance(abi, list)
        assert len(abi) > 0


def test_signer_roundtrip_and_domain_binding() -> None:
    digest = compute_model_digest("gemini-flash-lite-latest", DECISION_APPROVE, 420, "nominal withdrawal")
    assert len(digest) == 32

    sig = sign_verdict(
        private_key=TEST_PK,
        dest_chain_id=BASE_SEPOLIA_CHAIN_ID,
        vault_address=VAULT_ADDR,
        intent_id=7,
        decision=DECISION_APPROVE,
        risk_score_bps=420,
        expiry_ts=1_800_000_000,
        model_digest=digest,
    )
    assert len(sig) == 65
    recovered = recover_verdict_signer(
        dest_chain_id=BASE_SEPOLIA_CHAIN_ID,
        vault_address=VAULT_ADDR,
        intent_id=7,
        decision=DECISION_APPROVE,
        risk_score_bps=420,
        expiry_ts=1_800_000_000,
        model_digest=digest,
        signature=sig,
    )
    assert recovered == Web3.to_checksum_address(TEST_ADDR)

    # Mutating chainId or amount changes recovered address (domain separation proof).
    wrong_chain_signer = recover_verdict_signer(
        dest_chain_id=1301,
        vault_address=VAULT_ADDR,
        intent_id=7,
        decision=DECISION_APPROVE,
        risk_score_bps=420,
        expiry_ts=1_800_000_000,
        model_digest=digest,
        signature=sig,
    )
    assert wrong_chain_signer != recovered


def test_signer_invalid_digest_length_raises() -> None:
    with pytest.raises(ValueError, match="32 bytes"):
        compute_verdict_struct_hash(
            BASE_SEPOLIA_CHAIN_ID,
            VAULT_ADDR,
            1,
            DECISION_APPROVE,
            0,
            100,
            b"\x01\x02",
        )


def test_signer_parity_with_foundry_cast_abi_encode() -> None:
    cast_exe = shutil.which("cast") or r"C:\Users\Wiwit\.foundry\bin\cast.exe"
    if not Path(cast_exe).exists():
        pytest.skip("cast binary not available")

    digest = compute_model_digest("gemini-flash-lite-latest", DECISION_FREEZE_EMERGENCY, 9500, "critical drain")
    encoded = subprocess.check_output(
        [
            cast_exe,
            "abi-encode",
            "f(uint256,address,uint256,uint8,uint16,uint64,bytes32)",
            str(BASE_SEPOLIA_CHAIN_ID),
            VAULT_ADDR,
            "42",
            "2",
            "9500",
            "1799999999",
            "0x" + digest.hex(),
        ],
        text=True,
    ).strip()
    cast_hash = subprocess.check_output([cast_exe, "keccak", encoded], text=True).strip()
    py_hash = "0x" + compute_verdict_struct_hash(
        BASE_SEPOLIA_CHAIN_ID,
        VAULT_ADDR,
        42,
        DECISION_FREEZE_EMERGENCY,
        9500,
        1799999999,
        digest,
    ).hex()
    assert py_hash.lower() == cast_hash.lower()


def test_deterministic_risk_baseline_scenarios() -> None:
    dec, score, signals = deterministic_risk_baseline(_make_telemetry(anomaly_hint_bps=100))
    assert dec == "APPROVE"
    assert score < 4500
    assert "NOMINAL_VAULT_PARAMETERS" in signals

    dec_rej, score_rej, _ = deterministic_risk_baseline(
        _make_telemetry(amount_wei=Web3.to_wei(480, "ether"), anomaly_hint_bps=5000)
    )
    assert dec_rej == "REJECT"
    assert 4500 <= score_rej < 8200

    dec_freeze, score_freeze, sig_freeze = deterministic_risk_baseline(
        _make_telemetry(
            amount_wei=Web3.to_wei(850, "ether"),
            anomaly_hint_bps=9200,
            actor=RECIPIENT_ADDR,
        )
    )
    assert dec_freeze == "FREEZE_EMERGENCY"
    assert score_freeze >= 8200
    assert "EXCEEDS_MAX_SINGLE_INTENT_CAP" in sig_freeze
    assert "SELF_EXTRACTION_UNDER_ANOMALY" in sig_freeze


def test_evaluate_intent_gemini_mocked_and_guardrail_override() -> None:
    t_normal = _make_telemetry(anomaly_hint_bps=150)
    mock_resp = MagicMock()
    mock_resp.raise_for_status.return_value = None
    mock_resp.json.return_value = {
        "candidates": [
            {
                "content": {
                    "parts": [
                        {
                            "text": json.dumps(
                                {
                                    "decision": "APPROVE",
                                    "risk_score_bps": 450,
                                    "confidence": 0.96,
                                    "rationale": "Routine small treasury withdrawal within nominal cap.",
                                    "signals": ["NOMINAL_AMOUNT"],
                                }
                            )
                        }
                    ]
                }
            }
        ]
    }
    with patch("synapse_agent.analyzer.httpx.Client") as mock_client:
        mock_client.return_value.__enter__.return_value.post.return_value = mock_resp
        verdict = evaluate_intent_with_gemini(t_normal, api_key="test-key", model_name="gemini-flash-lite-latest")
        assert verdict.decision == DECISION_APPROVE
        assert verdict.risk_score_bps == 450
        assert verdict.engine == "gemini-flash-lite-latest"

    # Guardrail override: even if Gemini erroneously returns APPROVE during an extreme anomaly + drain, code overrides!
    t_exploit = _make_telemetry(amount_wei=Web3.to_wei(950, "ether"), anomaly_hint_bps=9600)
    with patch("synapse_agent.analyzer.httpx.Client") as mock_client:
        mock_client.return_value.__enter__.return_value.post.return_value = mock_resp
        verdict_safe = evaluate_intent_with_gemini(t_exploit, api_key="test-key")
        assert verdict_safe.decision == DECISION_FREEZE_EMERGENCY
        assert verdict_safe.risk_score_bps >= 8200
        assert "Guardrail Override" in verdict_safe.rationale


def test_evaluate_intent_retry_and_fallback_behavior() -> None:
    t = _make_telemetry(anomaly_hint_bps=200)
    with patch("synapse_agent.analyzer.httpx.Client") as mock_client, patch("synapse_agent.analyzer.time.sleep"):
        mock_client.return_value.__enter__.return_value.post.side_effect = RuntimeError("503 transient")
        with pytest.raises(RuntimeError, match="failed after retries"):
            evaluate_intent_with_gemini(t, api_key="test-key", allow_heuristic_fallback=False)

        fallback_verdict = evaluate_intent_with_gemini(t, api_key="test-key", allow_heuristic_fallback=True)
        assert fallback_verdict.engine == "heuristic-fallback"
        assert fallback_verdict.decision == DECISION_APPROVE


def test_compute_summary_and_deployment_config_loading(tmp_path: Path) -> None:
    dep_file = tmp_path / "deployments.json"
    dep_file.write_text(
        json.dumps(
            {
                "lasna": {"SynapseReactor": VAULT_ADDR},
                "baseSepolia": {"SynapseGuardVault": ACTOR_ADDR, "DemoToken": TOKEN_ADDR},
                "unichainSepolia": {"SynapseUnichainSentinel": RECIPIENT_ADDR},
                "aiSignerAddress": TEST_ADDR,
                "deployerAddress": TEST_ADDR,
            }
        ),
        encoding="utf-8",
    )
    cfg = DeploymentConfig.from_file(dep_file)
    assert cfg.synapse_reactor == VAULT_ADDR
    assert cfg.synapse_guard_vault == ACTOR_ADDR
    assert cfg.synapse_unichain_sentinel == RECIPIENT_ADDR

    traces = [
        IntentExecutionTrace(
            intent_id=i + 1,
            scenario=f"s{i}",
            origin_propose_tx="0x1",
            lasna_submit_tx="0x2",
            base_settlement_tx="0x3",
            unichain_freeze_tx=None,
            lasna_sync_tx="0x4",
            decision="APPROVE",
            risk_score_bps=200,
            confidence=0.95,
            rationale="ok",
            engine="gemini-flash-lite-latest",
            model_digest_hex="0x" + "00" * 32,
            vault_outcome_code=2,
            vault_outcome_name="EXECUTED",
            vault_executed=True,
            lasna_synced=True,
            unichain_locked_after=False,
            gemini_latency_ms=400.0 + i * 50,
            lasna_pickup_latency_ms=1200.0,
            total_e2e_latency_ms=6500.0 + i * 200,
            created_utc="2026-11-22T00:00:00Z",
        )
        for i in range(4)
    ]
    summary = _compute_summary(traces)
    assert summary["total_loops"] == 4
    assert summary["all_lasna_synced"] is True
    assert summary["median_e2e_latency_ms"] >= 6500.0
