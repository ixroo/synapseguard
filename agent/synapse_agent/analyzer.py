"""Two-stage quantitative + Gemini structured AI risk analyzer for SynapseGuard intents."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Literal

import httpx
from pydantic import BaseModel, Field

from synapse_agent.config import (
    DECISION_APPROVE,
    DECISION_FREEZE_EMERGENCY,
    DECISION_REJECT,
    DECISION_NAMES,
)
from synapse_agent.signer import compute_model_digest


class GeminiVerdictPayload(BaseModel):
    decision: Literal["APPROVE", "REJECT", "FREEZE_EMERGENCY"]
    risk_score_bps: int = Field(ge=0, le=10000)
    confidence: float = Field(ge=0.0, le=1.0)
    rationale: str = Field(min_length=4, max_length=280)
    signals: list[str] = Field(default_factory=list)


@dataclass(frozen=True)
class IntentTelemetry:
    intent_id: int
    actor: str
    recipient: str
    token: str
    is_native_eth: bool
    amount_wei: int
    vault_liquidity_wei: int
    max_single_intent_wei: int
    anomaly_hint_bps: int
    ttl_remaining_sec: int
    emergency_frozen: bool
    context_hash_hex: str

    @property
    def liquidity_utilization_bps(self) -> int:
        if self.vault_liquidity_wei <= 0:
            return 10000
        return min(10000, int((self.amount_wei * 10000) // self.vault_liquidity_wei))

    @property
    def cap_utilization_bps(self) -> int:
        if self.max_single_intent_wei <= 0:
            return 0
        return min(10000, int((self.amount_wei * 10000) // self.max_single_intent_wei))


@dataclass(frozen=True)
class AnalyzedVerdict:
    decision: int
    decision_name: str
    risk_score_bps: int
    confidence: float
    rationale: str
    signals: list[str]
    model_digest: bytes
    engine: str
    latency_ms: float


_DECISION_STR_TO_INT: dict[str, int] = {
    "REJECT": DECISION_REJECT,
    "APPROVE": DECISION_APPROVE,
    "FREEZE_EMERGENCY": DECISION_FREEZE_EMERGENCY,
}


def deterministic_risk_baseline(t: IntentTelemetry) -> tuple[str, int, list[str]]:
    """Compute quantitative on-chain threat score and baseline signals before LLM synthesis."""
    signals: list[str] = []
    score = int(t.anomaly_hint_bps * 0.45)

    liq_bps = t.liquidity_utilization_bps
    cap_bps = t.cap_utilization_bps

    if t.emergency_frozen:
        signals.append("VAULT_ALREADY_FROZEN")
        score = max(score, 9500)

    if t.amount_wei > t.vault_liquidity_wei:
        signals.append("INSUFFICIENT_VAULT_LIQUIDITY")
        score = max(score, 8500)

    if t.max_single_intent_wei > 0 and t.amount_wei > t.max_single_intent_wei:
        signals.append("EXCEEDS_MAX_SINGLE_INTENT_CAP")
        score = max(score, 9000)

    if liq_bps >= 8000:
        signals.append(f"SEVERE_LIQUIDITY_DRAIN_BPS:{liq_bps}")
        score += 3200
    elif liq_bps >= 4500:
        signals.append(f"HIGH_LIQUIDITY_UTILIZATION_BPS:{liq_bps}")
        score += 1800

    if cap_bps >= 9000:
        signals.append(f"NEAR_CAP_UTILIZATION_BPS:{cap_bps}")
        score += 1400

    if t.anomaly_hint_bps >= 8000:
        signals.append(f"CRITICAL_ANOMALY_HINT_BPS:{t.anomaly_hint_bps}")
        score += 2500
    elif t.anomaly_hint_bps >= 4000:
        signals.append(f"ELEVATED_ANOMALY_HINT_BPS:{t.anomaly_hint_bps}")
        score += 1200

    if t.actor.lower() == t.recipient.lower() and t.anomaly_hint_bps >= 6000:
        signals.append("SELF_EXTRACTION_UNDER_ANOMALY")
        score += 1000

    if t.ttl_remaining_sec < 10:
        signals.append("LOW_TTL_WINDOW")

    score = max(0, min(10000, score))
    if score >= 8200 or ("EXCEEDS_MAX_SINGLE_INTENT_CAP" in signals and t.anomaly_hint_bps >= 7000):
        baseline = "FREEZE_EMERGENCY"
    elif score >= 4500 or "INSUFFICIENT_VAULT_LIQUIDITY" in signals or "EXCEEDS_MAX_SINGLE_INTENT_CAP" in signals:
        baseline = "REJECT"
    else:
        baseline = "APPROVE"

    if not signals:
        signals.append("NOMINAL_VAULT_PARAMETERS")
    return baseline, score, signals


def evaluate_intent_with_gemini(
    telemetry: IntentTelemetry,
    api_key: str,
    model_name: str = "gemini-flash-lite-latest",
    timeout_sec: float = 15.0,
    allow_heuristic_fallback: bool = False,
) -> AnalyzedVerdict:
    """Evaluate cross-chain vault intent using Google Gemini structured JSON output."""
    t0 = time.perf_counter()
    baseline_dec, baseline_score, signals = deterministic_risk_baseline(telemetry)

    if not api_key:
        if not allow_heuristic_fallback:
            raise RuntimeError("GEMINI_API_KEY missing and fallback disabled.")
        return _build_fallback_verdict(
            baseline_dec, baseline_score, signals, model_name="heuristic-offline", start_ts=t0
        )

    prompt = (
        "You are SynapseGuard, an autonomous on-chain Web3 Treasury Security AI sitting inside a "
        "Reactive Omni cross-chain defense loop (Base Sepolia Vault <-> Reactive Lasna <-> Unichain Sentinel).\n"
        "Classify this withdrawal/execution intent strictly into APPROVE, REJECT, or FREEZE_EMERGENCY:\n"
        "- APPROVE: low anomaly hint, healthy liquidity utilization (<45% of vault), within cap.\n"
        "- REJECT: moderate/high risk (risk_score_bps 4500..8199), cap breach, or insufficient liquidity without systemic exploit indicators.\n"
        "- FREEZE_EMERGENCY: critical exploit pattern (risk_score_bps >= 8200, e.g. >75% anomaly hint combined with near-total drain or severe exploit signals). "
        "FREEZE_EMERGENCY locks both Base Sepolia and Unichain Sepolia.\n\n"
        f"Telemetry JSON:\n{json.dumps(_telemetry_prompt_dict(telemetry, baseline_dec, baseline_score, signals), indent=2)}"
    )

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model_name}:generateContent"
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.1,
            "maxOutputTokens": 256,
            "responseMimeType": "application/json",
            "responseSchema": {
                "type": "OBJECT",
                "properties": {
                    "decision": {
                        "type": "STRING",
                        "enum": ["APPROVE", "REJECT", "FREEZE_EMERGENCY"],
                    },
                    "risk_score_bps": {"type": "INTEGER"},
                    "confidence": {"type": "NUMBER"},
                    "rationale": {"type": "STRING"},
                    "signals": {"type": "ARRAY", "items": {"type": "STRING"}},
                },
                "required": ["decision", "risk_score_bps", "confidence", "rationale", "signals"],
            },
        },
    }

    last_err: Exception | None = None
    for attempt in range(3):
        try:
            with httpx.Client(timeout=timeout_sec) as client:
                resp = client.post(url, params={"key": api_key}, json=payload)
                resp.raise_for_status()
                body = resp.json()
            text = body["candidates"][0]["content"]["parts"][0]["text"]
            parsed = GeminiVerdictPayload.model_validate_json(text)
            dec_int = _DECISION_STR_TO_INT[parsed.decision]
            # Fail-closed safety invariant: never allow LLM hallucination to override hard cap/frozen danger downward.
            if baseline_dec == "FREEZE_EMERGENCY" and telemetry.anomaly_hint_bps >= 8500 and dec_int == DECISION_APPROVE:
                dec_int = DECISION_FREEZE_EMERGENCY
                parsed = parsed.model_copy(
                    update={
                        "decision": "FREEZE_EMERGENCY",
                        "risk_score_bps": max(parsed.risk_score_bps, baseline_score),
                        "rationale": f"[Guardrail Override] {parsed.rationale}"[:280],
                    }
                )
            elif "EXCEEDS_MAX_SINGLE_INTENT_CAP" in signals and dec_int == DECISION_APPROVE:
                dec_int = DECISION_REJECT
                parsed = parsed.model_copy(
                    update={
                        "decision": "REJECT",
                        "risk_score_bps": max(parsed.risk_score_bps, baseline_score),
                    }
                )

            digest = compute_model_digest(
                model_name=model_name,
                decision=dec_int,
                risk_score_bps=parsed.risk_score_bps,
                rationale=parsed.rationale,
            )
            return AnalyzedVerdict(
                decision=dec_int,
                decision_name=DECISION_NAMES[dec_int],
                risk_score_bps=parsed.risk_score_bps,
                confidence=parsed.confidence,
                rationale=parsed.rationale,
                signals=parsed.signals or signals,
                model_digest=digest,
                engine=model_name,
                latency_ms=(time.perf_counter() - t0) * 1000.0,
            )
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            if attempt < 2:
                time.sleep(0.6 * (attempt + 1))

    if allow_heuristic_fallback:
        return _build_fallback_verdict(
            baseline_dec,
            baseline_score,
            signals + [f"GEMINI_FALLBACK:{type(last_err).__name__}"],
            model_name="heuristic-fallback",
            start_ts=t0,
        )
    raise RuntimeError(f"Gemini risk evaluation failed after retries: {last_err}")


def _telemetry_prompt_dict(
    t: IntentTelemetry,
    baseline_dec: str,
    baseline_score: int,
    signals: list[str],
) -> dict[str, Any]:
    return {
        "intent_id": t.intent_id,
        "asset_type": "NATIVE_ETH" if t.is_native_eth else "ERC20",
        "amount_wei": str(t.amount_wei),
        "vault_liquidity_wei": str(t.vault_liquidity_wei),
        "liquidity_utilization_bps": t.liquidity_utilization_bps,
        "max_single_intent_wei": str(t.max_single_intent_wei),
        "cap_utilization_bps": t.cap_utilization_bps,
        "anomaly_hint_bps": t.anomaly_hint_bps,
        "ttl_remaining_sec": t.ttl_remaining_sec,
        "vault_already_frozen": t.emergency_frozen,
        "quantitative_baseline": {
            "decision": baseline_dec,
            "score_bps": baseline_score,
            "signals": signals,
        },
    }


def _build_fallback_verdict(
    decision_str: str,
    score_bps: int,
    signals: list[str],
    model_name: str,
    start_ts: float,
) -> AnalyzedVerdict:
    dec_int = _DECISION_STR_TO_INT[decision_str]
    rationale = f"Deterministic risk fallback: {decision_str} ({', '.join(signals[:3])})"[:280]
    digest = compute_model_digest(model_name, dec_int, score_bps, rationale)
    return AnalyzedVerdict(
        decision=dec_int,
        decision_name=DECISION_NAMES[dec_int],
        risk_score_bps=score_bps,
        confidence=0.85,
        rationale=rationale,
        signals=signals,
        model_digest=digest,
        engine=model_name,
        latency_ms=(time.perf_counter() - start_ts) * 1000.0,
    )
