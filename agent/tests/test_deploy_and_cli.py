"""Unit tests covering deployment utilities, orchestrator state polling, and CLI parsing."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from eth_account import Account
from web3 import Web3

from synapse_agent.config import (
    BASE_SEPOLIA_CHAIN_ID,
    DECISION_APPROVE,
    DeploymentConfig,
    RuntimeSettings,
)
from synapse_agent.deploy import check_and_maybe_bridge_lreact, load_bytecode
from synapse_agent.orchestrator import SynapseOrchestrator, write_trace_report


def test_load_bytecode_all_contracts() -> None:
    for name in ("SynapseReactor", "SynapseGuardVault", "SynapseUnichainSentinel", "DemoToken"):
        bc = load_bytecode(name)
        assert bc.startswith("0x")
        assert len(bc) > 100


def test_bridge_lreact_skips_when_already_funded() -> None:
    w3_base = MagicMock()
    w3_lasna = MagicMock()
    w3_lasna.eth.get_balance.return_value = Web3.to_wei("2.0", "ether")
    pk = "0x" + "11" * 32
    addr = Account.from_key(pk).address

    check_and_maybe_bridge_lreact(
        w3_base=w3_base,
        w3_lasna=w3_lasna,
        deployer_pk=pk,
        deployer_addr=addr,
        min_lreact_wei=Web3.to_wei("1.2", "ether"),
        base_eth_to_convert_wei=Web3.to_wei("0.025", "ether"),
    )
    w3_base.eth.get_balance.assert_not_called()


def test_bridge_lreact_raises_when_base_insufficient() -> None:
    w3_base = MagicMock()
    w3_lasna = MagicMock()
    w3_lasna.eth.get_balance.return_value = 0
    w3_base.eth.get_balance.return_value = Web3.to_wei("0.005", "ether")
    pk = "0x" + "11" * 32
    addr = Account.from_key(pk).address

    with pytest.raises(RuntimeError, match="Insufficient funds"):
        check_and_maybe_bridge_lreact(
            w3_base=w3_base,
            w3_lasna=w3_lasna,
            deployer_pk=pk,
            deployer_addr=addr,
            min_lreact_wei=Web3.to_wei("1.2", "ether"),
            base_eth_to_convert_wei=Web3.to_wei("0.025", "ether"),
        )


def test_write_trace_report_creates_json(tmp_path: Path) -> None:
    out = tmp_path / "sub" / "report.json"
    write_trace_report(out, [], extra={"custom_flag": True})
    data = json.loads(out.read_text(encoding="utf-8"))
    assert data["total_runs"] == 0
    assert data["custom_flag"] is True
    assert data["runs"] == []


def test_orchestrator_fetch_intent_telemetry_mocked() -> None:
    addr = Account.from_key("0x" + "11" * 32).address
    deploy = DeploymentConfig(
        synapse_reactor=addr,
        synapse_guard_vault=addr,
        synapse_unichain_sentinel=addr,
        demo_token=addr,
        ai_signer_address=addr,
        deployer_address=addr,
    )
    settings = RuntimeSettings(
        base_rpc_url="http://localhost:8545",
        lasna_rpc_url="http://localhost:8546",
        unichain_rpc_url="http://localhost:8547",
        gemini_api_key="dummy",
        gemini_model="gemini-flash-lite-latest",
        ai_signer_private_key="0x" + "11" * 32,
        submitter_private_key="0x" + "11" * 32,
    )
    orch = SynapseOrchestrator(settings, deploy)

    mock_vault = MagicMock()
    mock_vault.functions.getIntent.return_value.call.return_value = (
        addr,
        addr,
        "0x0000000000000000000000000000000000000000",
        Web3.to_wei("0.1", "ether"),
        250,
        1_700_000_000,
        1_900_000_000,
        b"\x22" * 32,
        1,
    )
    mock_vault.functions.vaultLiquidity.return_value.call.return_value = Web3.to_wei("2.0", "ether")
    mock_vault.functions.maxSingleIntentAmount.return_value.call.return_value = Web3.to_wei("1.0", "ether")
    mock_vault.functions.emergencyFrozen.return_value.call.return_value = False
    orch.vault = mock_vault

    t = orch.fetch_intent_telemetry(1)
    assert t.intent_id == 1
    assert t.is_native_eth is True
    assert t.liquidity_utilization_bps == 500
    assert t.cap_utilization_bps == 1000
    assert not t.emergency_frozen


def test_orchestrator_wait_for_lasna_pending_intent_polls() -> None:
    addr = Account.from_key("0x" + "11" * 32).address
    deploy = DeploymentConfig(addr, addr, addr, addr, addr, addr)
    settings = RuntimeSettings("http://a", "http://b", "http://c", "", "m", "", "")
    orch = SynapseOrchestrator(settings, deploy)

    call_mock = MagicMock()
    call_mock.call.side_effect = [
        (addr, addr, 0, 0, 0, b"", 0, 0, 0, b""),
        (addr, addr, 0, 0, 0, b"", 1, 0, 0, b""),
    ]
    orch.reactor = MagicMock()
    orch.reactor.functions.getTrackedIntent.return_value = call_mock

    with patch("synapse_agent.orchestrator.time.sleep"):
        ms = orch.wait_for_lasna_pending_intent(5, timeout_sec=10.0)
        assert ms >= 0.0
        assert call_mock.call.call_count == 2


def test_cli_probe_gemini_help_and_dispatch() -> None:
    from synapse_agent.cli import main

    with pytest.raises(SystemExit) as exc:
        main(["--help"])
    assert exc.value.code == 0


def test_video_demo_builds_all_slides_cleanly() -> None:
    from synapse_agent.video_demo import build_slides_html

    slides = build_slides_html(
        deploy={
            "lasna": {"SynapseReactor": "0x" + "1" * 40},
            "baseSepolia": {"SynapseGuardVault": "0x" + "2" * 40, "DemoToken": "0x" + "3" * 40},
            "unichainSepolia": {"SynapseUnichainSentinel": "0x" + "4" * 40},
            "aiSignerAddress": "0x" + "5" * 40,
            "sourcify": {"SynapseReactor": {"returncode": 0}},
        },
        bench={
            "summary": {"total_loops": 18, "median_e2e_latency_ms": 7200, "p95_e2e_latency_ms": 11500, "median_gemini_latency_ms": 620, "all_lasna_synced": True, "decisions": {"APPROVE": 12, "REJECT": 6}},
            "runs": [
                {"intent_id": 1, "scenario": "approve_susd_1", "vault_outcome_name": "EXECUTED", "risk_score_bps": 120, "confidence": 0.99, "origin_propose_tx": "0xaa", "lasna_submit_tx": "0xbb", "base_settlement_tx": "0xcc", "lasna_sync_tx": "0xdd", "total_e2e_latency_ms": 7100, "gemini_latency_ms": 580},
                {"intent_id": 2, "scenario": "reject_high_anomaly_1", "vault_outcome_name": "REJECTED_BY_AI", "risk_score_bps": 6500, "confidence": 0.94, "vault_executed": False, "origin_propose_tx": "0xee", "lasna_submit_tx": "0xff", "base_settlement_tx": "0x11", "lasna_sync_tx": "0x22"},
            ],
        },
        special={
            "emergency_freeze_loop": {"intent_id": 19, "risk_score_bps": 9400, "origin_propose_tx": "0x33", "lasna_submit_tx": "0x44", "base_settlement_tx": "0x55", "unichain_freeze_tx": "0x66", "lasna_sync_tx": "0x77"},
            "governance_unfreeze_sync": {"base_unfreeze_tx": "0x88", "unichain_unfreeze_tx": "0x99", "base_frozen_after": False, "unichain_locked_after": False},
            "ai_offline_cron_timeout_loop": {"intent_id": 20, "origin_propose_tx": "0xaa", "base_settlement_tx": "0xbb", "lasna_sync_tx": "0xcc", "outcome_name": "TIMED_OUT", "lasna_synced": True, "cron_subscribed_after": False},
        },
        mcp_health={"verdict": "OK_HEALTH", "summary": "Serving live on Lasna"},
    )
    assert len(slides) == 7  # Slide 4 is injected from live dashboard HTML during render
    assert all("SynapseGuard" in doc for _, _, doc in slides)
