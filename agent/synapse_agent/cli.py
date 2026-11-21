"""CLI utilities for running SynapseGuard AI agent, single loop probes, snapshots, and multi-loop benchmarks."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from web3 import Web3

from synapse_agent.analyzer import IntentTelemetry, evaluate_intent_with_gemini
from synapse_agent.config import (
    ARTIFACTS_DIR,
    DEPLOYMENTS_PATH,
    DeploymentConfig,
    RuntimeSettings,
)
from synapse_agent.orchestrator import IntentExecutionTrace, SynapseOrchestrator, write_trace_report


def cmd_snapshot(args: argparse.Namespace) -> int:
    settings = RuntimeSettings.from_env()
    deploy = DeploymentConfig.from_file(Path(args.deployments))
    orch = SynapseOrchestrator(settings, deploy)
    snap = orch.snapshot_chain_state()
    print(json.dumps(snap, indent=2))
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    settings = RuntimeSettings.from_env()
    deploy = DeploymentConfig.from_file(Path(args.deployments))
    orch = SynapseOrchestrator(settings, deploy)
    print(f"[SynapseAgent] Watching Lasna Reactor {deploy.synapse_reactor} (model={settings.gemini_model})")
    orch.watch_loop(
        poll_interval_sec=args.poll_interval,
        allow_heuristic_fallback=args.allow_fallback,
    )
    return 0


def cmd_benchmark(args: argparse.Namespace) -> int:
    settings = RuntimeSettings.from_env()
    deploy = DeploymentConfig.from_file(Path(args.deployments))
    orch = SynapseOrchestrator(settings, deploy)

    recipient = Web3.to_checksum_address(args.recipient or deploy.deployer_address)
    token = Web3.to_checksum_address(deploy.demo_token)
    zero_addr = "0x0000000000000000000000000000000000000000"

    scenarios: list[tuple[str, str, int, int, int]] = []
    # 1. Approve scenarios (mix of ERC-20 and native ETH micro-amounts so testnet reserves stay ample)
    for idx in range(args.approve_count):
        if idx % 4 == 3:
            scenarios.append((f"approve_native_eth_{idx+1}", zero_addr, Web3.to_wei("0.00005", "ether"), 120 + idx * 30, 90))
        else:
            scenarios.append((f"approve_susd_{idx+1}", token, Web3.to_wei(5 + idx, "ether"), 150 + idx * 45, 90))
    # 2. Reject scenarios (near-cap utilization + high anomaly hints without emergency severity)
    for idx in range(args.reject_count):
        scenarios.append((f"reject_high_anomaly_{idx+1}", token, Web3.to_wei(460 + idx * 5, "ether"), 6100 + idx * 200, 90))

    traces: list[IntentExecutionTrace] = []
    for name, tok, amt_wei, hint_bps, ttl in scenarios:
        print(f"[Benchmark] Running {name} (amount={amt_wei}, anomalyHintBps={hint_bps})...", flush=True)
        trace = orch.run_single_live_loop(
            scenario_name=name,
            recipient=recipient,
            token=tok,
            amount_wei=amt_wei,
            anomaly_hint_bps=hint_bps,
            ttl_seconds=ttl,
            allow_heuristic_fallback=args.allow_fallback,
        )
        traces.append(trace)
        print(
            f"  -> intent={trace.intent_id} {trace.decision} -> Base {trace.vault_outcome_name} "
            f"(e2e={trace.total_e2e_latency_ms}ms, gemini={trace.gemini_latency_ms}ms)",
            flush=True,
        )

    out_path = Path(args.output)
    summary = _compute_summary(traces)
    write_trace_report(out_path, traces, extra={"summary": summary, "snapshot": orch.snapshot_chain_state()})
    print(f"[Benchmark] Wrote {len(traces)} live loop traces to {out_path}")
    return 0


def cmd_probe_gemini(args: argparse.Namespace) -> int:
    settings = RuntimeSettings.from_env()
    t = IntentTelemetry(
        intent_id=999,
        actor="0x1d760Ef5F35f7ae3fE4B7a7196FBA945Fa4C9d0C",
        recipient="0x8E0bfff29c87E49815B8bCF95033ea6853854741",
        token="0x0000000000000000000000000000000000000000",
        is_native_eth=True,
        amount_wei=Web3.to_wei("0.01", "ether"),
        vault_liquidity_wei=Web3.to_wei("1.0", "ether"),
        max_single_intent_wei=Web3.to_wei("0.5", "ether"),
        anomaly_hint_bps=args.anomaly_bps,
        ttl_remaining_sec=90,
        emergency_frozen=False,
        context_hash_hex="0x" + "11" * 32,
    )
    verdict = evaluate_intent_with_gemini(
        t,
        api_key=settings.gemini_api_key,
        model_name=settings.gemini_model,
        allow_heuristic_fallback=False,
    )
    print(
        json.dumps(
            {
                "decision": verdict.decision_name,
                "risk_score_bps": verdict.risk_score_bps,
                "confidence": verdict.confidence,
                "rationale": verdict.rationale,
                "signals": verdict.signals,
                "engine": verdict.engine,
                "latency_ms": round(verdict.latency_ms, 2),
                "model_digest": "0x" + verdict.model_digest.hex(),
            },
            indent=2,
        )
    )
    return 0


def _compute_summary(traces: list[IntentExecutionTrace]) -> dict[str, Any]:
    if not traces:
        return {}
    e2e = sorted(t.total_e2e_latency_ms for t in traces if t.total_e2e_latency_ms is not None)
    gem = sorted(t.gemini_latency_ms for t in traces)
    decisions: dict[str, int] = {}
    for t in traces:
        decisions[t.decision] = decisions.get(t.decision, 0) + 1
    return {
        "total_loops": len(traces),
        "decisions": decisions,
        "all_lasna_synced": all(t.lasna_synced for t in traces),
        "median_e2e_latency_ms": round(e2e[len(e2e) // 2], 2) if e2e else None,
        "p95_e2e_latency_ms": round(e2e[min(len(e2e) - 1, int(len(e2e) * 0.95))], 2) if e2e else None,
        "median_gemini_latency_ms": round(gem[len(gem) // 2], 2) if gem else None,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="synapse-agent")
    sub = parser.add_subparsers(dest="command", required=True)

    p_snap = sub.add_parser("snapshot", help="Print live state snapshot across Base, Lasna, and Unichain")
    p_snap.add_argument("--deployments", default=str(DEPLOYMENTS_PATH))
    p_snap.set_defaults(func=cmd_snapshot)

    p_watch = sub.add_parser("watch", help="Watch Reactive Lasna and sign/submit Gemini verdicts")
    p_watch.add_argument("--deployments", default=str(DEPLOYMENTS_PATH))
    p_watch.add_argument("--poll-interval", type=float, default=2.0)
    p_watch.add_argument("--allow-fallback", action="store_true")
    p_watch.set_defaults(func=cmd_watch)

    p_bench = sub.add_parser("benchmark", help="Run automated live multi-chain benchmark loops")
    p_bench.add_argument("--deployments", default=str(DEPLOYMENTS_PATH))
    p_bench.add_argument("--recipient", default="")
    p_bench.add_argument("--approve-count", type=int, default=12)
    p_bench.add_argument("--reject-count", type=int, default=6)
    p_bench.add_argument("--allow-fallback", action="store_true")
    p_bench.add_argument("--output", default=str(ARTIFACTS_DIR / "live_benchmark.json"))
    p_bench.set_defaults(func=cmd_benchmark)

    p_probe = sub.add_parser("probe-gemini", help="Run one live Gemini evaluation check")
    p_probe.add_argument("--anomaly-bps", type=int, default=150)
    p_probe.set_defaults(func=cmd_probe_gemini)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
