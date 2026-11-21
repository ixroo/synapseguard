"""Configuration and multi-chain network definitions for SynapseGuard."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ENV_PATH = PROJECT_ROOT / ".env"
OUT_DIR = PROJECT_ROOT / "out"
ARTIFACTS_DIR = PROJECT_ROOT / "artifacts"
DEPLOYMENTS_PATH = ARTIFACTS_DIR / "deployments.json"

BASE_SEPOLIA_CHAIN_ID = 84532
LASNA_CHAIN_ID = 5318007
UNICHAIN_SEPOLIA_CHAIN_ID = 1301

BASE_CALLBACK_PROXY = "0x476F44b11F5C942c58f4c8E3d0300E5710743585"
UNICHAIN_CALLBACK_PROXY = "0x775c9B990ADe401060B78D0e98684eEf8d2466C1"
LASNA_SYSTEM_CONTRACT = "0x8888888888888888888888888888888888888888"

DECISION_REJECT = 0
DECISION_APPROVE = 1
DECISION_FREEZE_EMERGENCY = 2

DECISION_NAMES: dict[int, str] = {
    DECISION_REJECT: "REJECT",
    DECISION_APPROVE: "APPROVE",
    DECISION_FREEZE_EMERGENCY: "FREEZE_EMERGENCY",
}

OUTCOME_NAMES: dict[int, str] = {
    0: "NONE",
    1: "REJECTED_BY_AI",
    2: "EXECUTED",
    3: "FROZEN_BY_AI",
    4: "TIMED_OUT",
    5: "REJECTED_GUARDRAIL",
}


def load_dotenv(path: Path = ENV_PATH) -> None:
    """Populate os.environ from a local .env file without overwriting existing env vars."""
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = val


@dataclass(frozen=True)
class DeploymentConfig:
    synapse_reactor: str
    synapse_guard_vault: str
    synapse_unichain_sentinel: str
    demo_token: str
    ai_signer_address: str
    deployer_address: str

    @classmethod
    def from_file(cls, path: Path = DEPLOYMENTS_PATH) -> "DeploymentConfig":
        data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
        return cls(
            synapse_reactor=data["lasna"]["SynapseReactor"],
            synapse_guard_vault=data["baseSepolia"]["SynapseGuardVault"],
            synapse_unichain_sentinel=data["unichainSepolia"]["SynapseUnichainSentinel"],
            demo_token=data["baseSepolia"]["DemoToken"],
            ai_signer_address=data["aiSignerAddress"],
            deployer_address=data["deployerAddress"],
        )


@dataclass(frozen=True)
class RuntimeSettings:
    base_rpc_url: str
    lasna_rpc_url: str
    unichain_rpc_url: str
    gemini_api_key: str
    gemini_model: str
    ai_signer_private_key: str
    submitter_private_key: str

    @classmethod
    def from_env(cls) -> "RuntimeSettings":
        load_dotenv()
        return cls(
            base_rpc_url=os.getenv("BASE_SEPOLIA_RPC", "https://base-sepolia-rpc.publicnode.com"),
            lasna_rpc_url=os.getenv("LASNA_RPC", "https://lasna-rpc.rnk.dev/"),
            unichain_rpc_url=os.getenv("UNICHAIN_SEPOLIA_RPC", "https://sepolia.unichain.org"),
            gemini_api_key=os.getenv("GEMINI_API_KEY", ""),
            gemini_model=os.getenv("GEMINI_MODEL", "gemini-flash-lite-latest"),
            ai_signer_private_key=os.getenv("AI_SIGNER_PRIVATE_KEY", ""),
            submitter_private_key=os.getenv("AI_SUBMITTER_PRIVATE_KEY", os.getenv("DEPLOYER_PRIVATE_KEY", "")),
        )
