"""ABI loader reading compiled Foundry artifacts under out/ with graceful validation."""

from __future__ import annotations

import json
from functools import lru_cache
from typing import Any

from synapse_agent.config import OUT_DIR


@lru_cache(maxsize=16)
def load_contract_abi(contract_name: str, file_name: str | None = None) -> list[dict[str, Any]]:
    sol_name = file_name or f"{contract_name}.sol"
    artifact_path = OUT_DIR / sol_name / f"{contract_name}.json"
    if not artifact_path.exists():
        raise FileNotFoundError(
            f"Compiled Foundry artifact missing at {artifact_path}. Run 'forge build' first."
        )
    data = json.loads(artifact_path.read_text(encoding="utf-8"))
    return data["abi"]
