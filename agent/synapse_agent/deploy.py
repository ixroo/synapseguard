"""Idempotent 3-chain deployer, Sourcify verifier, and full adversarial live demo runner."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from eth_account import Account
from web3 import Web3

from synapse_agent.abi import load_contract_abi
from synapse_agent.config import (
    ARTIFACTS_DIR,
    BASE_CALLBACK_PROXY,
    BASE_SEPOLIA_CHAIN_ID,
    DEPLOYMENTS_PATH,
    LASNA_CHAIN_ID,
    OUT_DIR,
    UNICHAIN_CALLBACK_PROXY,
    UNICHAIN_SEPOLIA_CHAIN_ID,
    DeploymentConfig,
    RuntimeSettings,
    load_dotenv,
)
from synapse_agent.orchestrator import SynapseOrchestrator, write_trace_report


BASE_REACTIVE_FAUCET = "0x2afaFD298b23b62760711756088F75B7409f5967"
ETH_REACTIVE_FAUCET = "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434"
BASE_SEPOLIA_L1_PORTAL = "0x49f53e41452C74589E85cA1677426Ba426459e85"
UNICHAIN_SEPOLIA_L1_PORTAL = "0x0d83dab629f0e0F9d36c0Cbc89B69a489f0751bD"

FAUCET_ABI = [
    {
        "inputs": [{"internalType": "address", "name": "recipient", "type": "address"}],
        "name": "request",
        "outputs": [],
        "stateMutability": "payable",
        "type": "function",
    }
]
PORTAL_ABI = [
    {
        "inputs": [
            {"internalType": "address", "name": "_to", "type": "address"},
            {"internalType": "uint256", "name": "_value", "type": "uint256"},
            {"internalType": "uint64", "name": "_gasLimit", "type": "uint64"},
            {"internalType": "bool", "name": "_isCreation", "type": "bool"},
            {"internalType": "bytes", "name": "_data", "type": "bytes"},
        ],
        "name": "depositTransaction",
        "outputs": [],
        "stateMutability": "payable",
        "type": "function",
    }
]


def load_bytecode(contract_name: str, file_name: str | None = None) -> str:
    sol_name = file_name or f"{contract_name}.sol"
    artifact_path = OUT_DIR / sol_name / f"{contract_name}.json"
    data = json.loads(artifact_path.read_text(encoding="utf-8"))
    return data["bytecode"]["object"]


def deploy_contract(
    w3: Web3,
    private_key: str,
    contract_name: str,
    ctor_args: list[Any],
    gas: int = 3_000_000,
    value_wei: int = 0,
) -> tuple[str, str]:
    abi = load_contract_abi(contract_name)
    bytecode = load_bytecode(contract_name)
    acct = Account.from_key(private_key)
    factory = w3.eth.contract(abi=abi, bytecode=bytecode)
    nonce = w3.eth.get_transaction_count(acct.address, "pending")
    gas_price = max(int(w3.eth.gas_price * 1.25), 1_000_000)
    tx = factory.constructor(*ctor_args).build_transaction(
        {
            "from": acct.address,
            "nonce": nonce,
            "gas": gas,
            "gasPrice": gas_price,
            "chainId": w3.eth.chain_id,
            "value": value_wei,
        }
    )
    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt.status != 1 or not receipt.contractAddress:
        raise RuntimeError(f"Deployment of {contract_name} failed: tx={tx_hash.hex()}")
    return Web3.to_checksum_address(receipt.contractAddress), "0x" + tx_hash.hex().lstrip("0x")


def send_contract_tx(
    w3: Web3,
    private_key: str,
    fn_call: Any,
    gas: int = 400_000,
    value_wei: int = 0,
) -> str:
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
            "value": value_wei,
        }
    )
    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt.status != 1:
        raise RuntimeError(f"Transaction reverted: tx={tx_hash.hex()}")
    raw = tx_hash.hex()
    return raw if raw.startswith("0x") else "0x" + raw


def check_and_maybe_bridge_lreact(
    w3_base: Web3,
    w3_lasna: Web3,
    deployer_pk: str,
    deployer_addr: str,
    min_lreact_wei: int,
    base_eth_to_convert_wei: int,
    w3_eth_sepolia: Web3 | None = None,
) -> None:
    lasna_bal = w3_lasna.eth.get_balance(deployer_addr)
    if lasna_bal >= min_lreact_wei:
        return

    # Prefer Ethereum Sepolia if funded cleanly (saves Base Sepolia gas reserves)
    if w3_eth_sepolia is not None:
        eth_bal = w3_eth_sepolia.eth.get_balance(deployer_addr)
        if eth_bal >= base_eth_to_convert_wei + Web3.to_wei("0.005", "ether"):
            eth_faucet = w3_eth_sepolia.eth.contract(
                address=Web3.to_checksum_address(ETH_REACTIVE_FAUCET), abi=FAUCET_ABI
            )
            print(f"[Deploy] Converting {Web3.from_wei(base_eth_to_convert_wei, 'ether')} Eth Sepolia -> lREACT...")
            tx_hex = send_contract_tx(
                w3_eth_sepolia,
                deployer_pk,
                eth_faucet.functions.request(deployer_addr),
                gas=120_000,
                value_wei=base_eth_to_convert_wei,
            )
            print(f"[Deploy] Eth Sepolia Reactive Faucet tx={tx_hex}; waiting for Lasna balance update...")
            deadline = time.perf_counter() + 90.0
            while time.perf_counter() < deadline:
                new_bal = w3_lasna.eth.get_balance(deployer_addr)
                if new_bal >= min_lreact_wei:
                    print(f"[Deploy] Lasna balance funded: {Web3.from_wei(new_bal, 'ether')} lREACT")
                    return
                time.sleep(2.0)
            raise TimeoutError("Timed out waiting for Reactive Faucet lREACT delivery on Lasna")

    base_bal = w3_base.eth.get_balance(deployer_addr)
    if base_bal < base_eth_to_convert_wei + Web3.to_wei("0.01", "ether"):
        raise RuntimeError(
            f"Insufficient funds for auto-bridge to Lasna: lasna={lasna_bal}, base={base_bal}. "
            f"Need Base Sepolia ETH (>=0.035 ETH), Ethereum Sepolia ETH (>=0.03 ETH), or direct lREACT."
        )
    faucet = w3_base.eth.contract(
        address=Web3.to_checksum_address(BASE_REACTIVE_FAUCET), abi=FAUCET_ABI
    )
    print(f"[Deploy] Converting {Web3.from_wei(base_eth_to_convert_wei, 'ether')} Base Sepolia ETH -> lREACT...")
    tx_hex = send_contract_tx(
        w3_base,
        deployer_pk,
        faucet.functions.request(deployer_addr),
        gas=120_000,
        value_wei=base_eth_to_convert_wei,
    )
    print(f"[Deploy] Reactive Faucet tx={tx_hex}; waiting for Lasna balance update...")
    deadline = time.perf_counter() + 90.0
    while time.perf_counter() < deadline:
        new_bal = w3_lasna.eth.get_balance(deployer_addr)
        if new_bal >= min_lreact_wei:
            print(f"[Deploy] Lasna balance funded: {Web3.from_wei(new_bal, 'ether')} lREACT")
            return
        time.sleep(2.0)
    raise TimeoutError("Timed out waiting for Reactive Faucet lREACT delivery on Lasna")


def check_and_maybe_bridge_l2_from_sepolia(
    w3_eth_sep: Web3,
    w3_base: Web3,
    w3_uni: Web3,
    deployer_pk: str,
    deployer_addr: str,
    min_base_wei: int,
    min_uni_wei: int,
) -> None:
    """Bridge Sepolia ETH cleanly to Base Sepolia and/or Unichain Sepolia via official OP Portals if L2 balances are low."""
    base_bal = w3_base.eth.get_balance(deployer_addr)
    uni_bal = w3_uni.eth.get_balance(deployer_addr)
    if base_bal >= min_base_wei and uni_bal >= min_uni_wei:
        return

    sep_bal = w3_eth_sep.eth.get_balance(deployer_addr)
    if sep_bal == 0:
        return

    need_base = max(0, Web3.to_wei("0.013", "ether") - base_bal) if base_bal < min_base_wei else 0
    need_uni = max(0, Web3.to_wei("0.005", "ether") - uni_bal) if uni_bal < min_uni_wei else 0
    reserve_l1_gas = Web3.to_wei("0.0008", "ether")

    if sep_bal < need_base + need_uni + reserve_l1_gas:
        raise RuntimeError(
            f"Insufficient Sepolia ETH ({Web3.from_wei(sep_bal, 'ether')} ETH) to bridge Base ({Web3.from_wei(need_base, 'ether')}) + Unichain ({Web3.from_wei(need_uni, 'ether')})."
        )

    if need_base > 0:
        portal_b = w3_eth_sep.eth.contract(
            address=Web3.to_checksum_address(BASE_SEPOLIA_L1_PORTAL), abi=PORTAL_ABI
        )
        print(f"[Deploy] Bridging {Web3.from_wei(need_base, 'ether')} Sepolia ETH -> Base Sepolia...")
        tx_b = send_contract_tx(
            w3_eth_sep,
            deployer_pk,
            portal_b.functions.depositTransaction(deployer_addr, need_base, 100_000, False, b""),
            gas=160_000,
            value_wei=need_base,
        )
        print(f"[Deploy] Base Sepolia Portal deposit tx={tx_b}")

    if need_uni > 0:
        portal_u = w3_eth_sep.eth.contract(
            address=Web3.to_checksum_address(UNICHAIN_SEPOLIA_L1_PORTAL), abi=PORTAL_ABI
        )
        print(f"[Deploy] Bridging {Web3.from_wei(need_uni, 'ether')} Sepolia ETH -> Unichain Sepolia...")
        tx_u = send_contract_tx(
            w3_eth_sep,
            deployer_pk,
            portal_u.functions.depositTransaction(deployer_addr, need_uni, 100_000, False, b""),
            gas=160_000,
            value_wei=need_uni,
        )
        print(f"[Deploy] Unichain Sepolia Portal deposit tx={tx_u}")

    print("[Deploy] Waiting for L2 Portal deposits to land on Base Sepolia & Unichain Sepolia...")
    deadline = time.perf_counter() + 420.0
    while time.perf_counter() < deadline:
        b_ok = w3_base.eth.get_balance(deployer_addr) >= min_base_wei
        u_ok = w3_uni.eth.get_balance(deployer_addr) >= min_uni_wei
        if b_ok and u_ok:
            print("[Deploy] Both L2 deposits landed cleanly.")
            return
        time.sleep(5.0)
    raise TimeoutError("Timed out waiting for L1->L2 Sepolia Portal deposits.")


def run_deploy(deployments_path: Path = DEPLOYMENTS_PATH, skip_verify: bool = False) -> dict[str, Any]:
    load_dotenv()
    settings = RuntimeSettings.from_env()
    deployer_pk = os.getenv("DEPLOYER_PRIVATE_KEY", "")
    ai_signer_addr = Web3.to_checksum_address(os.getenv("AI_SIGNER_ADDRESS", ""))
    if not deployer_pk or not ai_signer_addr:
        raise RuntimeError("Missing DEPLOYER_PRIVATE_KEY or AI_SIGNER_ADDRESS in .env")
    deployer_addr = Account.from_key(deployer_pk).address

    w3_lasna = Web3(Web3.HTTPProvider(settings.lasna_rpc_url, request_kwargs={"timeout": 30}))
    w3_base = Web3(Web3.HTTPProvider(settings.base_rpc_url, request_kwargs={"timeout": 30}))
    w3_uni = Web3(Web3.HTTPProvider(settings.unichain_rpc_url, request_kwargs={"timeout": 30}))
    w3_eth_sep = Web3(Web3.HTTPProvider(os.getenv("ETH_SEPOLIA_RPC", "https://ethereum-sepolia-rpc.publicnode.com"), request_kwargs={"timeout": 30}))

    existing: dict[str, Any] = {}
    if deployments_path.exists():
        existing = json.loads(deployments_path.read_text(encoding="utf-8"))

    # Pre-flight balance checks across 4 chains & bridge from Sepolia if needed
    base_bal = w3_base.eth.get_balance(deployer_addr)
    uni_bal = w3_uni.eth.get_balance(deployer_addr)
    lasna_bal = w3_lasna.eth.get_balance(deployer_addr)
    sep_bal = w3_eth_sep.eth.get_balance(deployer_addr)
    print(
        f"[Deploy] Wallet {deployer_addr} balances | "
        f"Sepolia={Web3.from_wei(sep_bal, 'ether'):.5f} | "
        f"Base={Web3.from_wei(base_bal, 'ether'):.5f} | "
        f"Unichain={Web3.from_wei(uni_bal, 'ether'):.5f} | "
        f"Lasna={Web3.from_wei(lasna_bal, 'ether'):.5f} lREACT"
    )
    check_and_maybe_bridge_lreact(
        w3_base=w3_base,
        w3_lasna=w3_lasna,
        deployer_pk=deployer_pk,
        deployer_addr=deployer_addr,
        min_lreact_wei=Web3.to_wei("2.5", "ether"),
        base_eth_to_convert_wei=Web3.to_wei("0.030", "ether"),
        w3_eth_sepolia=w3_eth_sep,
    )
    check_and_maybe_bridge_l2_from_sepolia(
        w3_eth_sep=w3_eth_sep,
        w3_base=w3_base,
        w3_uni=w3_uni,
        deployer_pk=deployer_pk,
        deployer_addr=deployer_addr,
        min_base_wei=Web3.to_wei("0.012", "ether"),
        min_uni_wei=Web3.to_wei("0.004", "ether"),
    )

    state: dict[str, Any] = existing or {
        "deployerAddress": deployer_addr,
        "aiSignerAddress": ai_signer_addr,
        "lasna": {"chainId": LASNA_CHAIN_ID},
        "baseSepolia": {"chainId": BASE_SEPOLIA_CHAIN_ID, "callbackProxy": BASE_CALLBACK_PROXY},
        "unichainSepolia": {"chainId": UNICHAIN_SEPOLIA_CHAIN_ID, "callbackProxy": UNICHAIN_CALLBACK_PROXY},
        "txs": {},
    }

    # 1. SynapseReactor on Lasna
    if "SynapseReactor" not in state["lasna"]:
        addr, tx = deploy_contract(w3_lasna, deployer_pk, "SynapseReactor", [], gas=2_800_000)
        state["lasna"]["SynapseReactor"] = addr
        state["txs"]["deploySynapseReactor"] = tx
        _save_json(deployments_path, state)
        print(f"[Deploy] SynapseReactor -> {addr} (tx={tx})")

    reactor_addr = Web3.to_checksum_address(state["lasna"]["SynapseReactor"])
    reactor = w3_lasna.eth.contract(address=reactor_addr, abi=load_contract_abi("SynapseReactor"))

    # 2. DemoToken on Base Sepolia
    if "DemoToken" not in state["baseSepolia"]:
        addr, tx = deploy_contract(
            w3_base,
            deployer_pk,
            "DemoToken",
            ["Synapse USD", "sUSD", 18, Web3.to_wei(100_000, "ether")],
            gas=1_600_000,
        )
        state["baseSepolia"]["DemoToken"] = addr
        state["txs"]["deployDemoToken"] = tx
        _save_json(deployments_path, state)
        print(f"[Deploy] DemoToken -> {addr} (tx={tx})")

    token_addr = Web3.to_checksum_address(state["baseSepolia"]["DemoToken"])

    # 3. SynapseGuardVault on Base Sepolia
    if "SynapseGuardVault" not in state["baseSepolia"]:
        addr, tx = deploy_contract(
            w3_base,
            deployer_pk,
            "SynapseGuardVault",
            [
                Web3.to_checksum_address(BASE_CALLBACK_PROXY),
                reactor_addr,
                ai_signer_addr,
                Web3.to_wei(500, "ether"),
            ],
            gas=2_600_000,
        )
        state["baseSepolia"]["SynapseGuardVault"] = addr
        state["txs"]["deploySynapseGuardVault"] = tx
        _save_json(deployments_path, state)
        print(f"[Deploy] SynapseGuardVault -> {addr} (tx={tx})")

    vault_addr = Web3.to_checksum_address(state["baseSepolia"]["SynapseGuardVault"])

    # 4. SynapseUnichainSentinel on Unichain Sepolia
    if "SynapseUnichainSentinel" not in state["unichainSepolia"]:
        addr, tx = deploy_contract(
            w3_uni,
            deployer_pk,
            "SynapseUnichainSentinel",
            [Web3.to_checksum_address(UNICHAIN_CALLBACK_PROXY), reactor_addr],
            gas=1_500_000,
        )
        state["unichainSepolia"]["SynapseUnichainSentinel"] = addr
        state["txs"]["deploySynapseUnichainSentinel"] = tx
        _save_json(deployments_path, state)
        print(f"[Deploy] SynapseUnichainSentinel -> {addr} (tx={tx})")

    sentinel_addr = Web3.to_checksum_address(state["unichainSepolia"]["SynapseUnichainSentinel"])

    # 5. Fund Base Vault liquidity + callback proxy reserves + Unichain Sentinel proxy reserves + Lasna Reactor system reserves
    vault = w3_base.eth.contract(address=vault_addr, abi=load_contract_abi("SynapseGuardVault"))
    demo_tok = w3_base.eth.contract(address=token_addr, abi=load_contract_abi("DemoToken"))
    sentinel = w3_uni.eth.contract(address=sentinel_addr, abi=load_contract_abi("SynapseUnichainSentinel"))

    if not state["txs"].get("vaultProxyFunded"):
        tx = send_contract_tx(w3_base, deployer_pk, vault.functions.depositToProxy(), gas=150_000, value_wei=Web3.to_wei("0.006", "ether"))
        state["txs"]["vaultProxyFunded"] = tx
        _save_json(deployments_path, state)
        print(f"[Fund] Base Vault callback proxy reserve funded tx={tx}")

    if not state["txs"].get("vaultLiquiditySeeded"):
        tx_eth = send_contract_tx(w3_base, deployer_pk, vault.functions.depositEth(), gas=120_000, value_wei=Web3.to_wei("0.002", "ether"))
        mint_amt = Web3.to_wei(10_000, "ether")
        tx_mint = send_contract_tx(w3_base, deployer_pk, demo_tok.functions.faucetMint(deployer_addr, mint_amt), gas=120_000)
        tx_app = send_contract_tx(w3_base, deployer_pk, demo_tok.functions.approve(vault_addr, mint_amt), gas=100_000)
        tx_dep = send_contract_tx(w3_base, deployer_pk, vault.functions.depositToken(token_addr, mint_amt), gas=150_000)
        state["txs"]["vaultLiquiditySeeded"] = {"eth": tx_eth, "mint": tx_mint, "approve": tx_app, "depositToken": tx_dep}
        _save_json(deployments_path, state)
        print(f"[Fund] Base Vault seeded 0.002 ETH + 10,000 sUSD")

    if not state["txs"].get("sentinelProxyFunded"):
        tx = send_contract_tx(w3_uni, deployer_pk, sentinel.functions.depositToProxy(), gas=150_000, value_wei=Web3.to_wei("0.002", "ether"))
        state["txs"]["sentinelProxyFunded"] = tx
        _save_json(deployments_path, state)
        print(f"[Fund] Unichain Sentinel proxy reserve funded tx={tx}")

    if not state["txs"].get("reactorSystemFunded"):
        tx = send_contract_tx(w3_lasna, deployer_pk, reactor.functions.depositToSystem(), gas=150_000, value_wei=Web3.to_wei("1.7", "ether"))
        state["txs"]["reactorSystemFunded"] = tx
        _save_json(deployments_path, state)
        print(f"[Fund] Lasna Reactor system reserves funded 1.7 lREACT tx={tx}")

    # 6. Configure and subscribe Reactor on Lasna (only if not yet configured)
    if not reactor.functions.configured().call():
        tx = send_contract_tx(
            w3_lasna,
            deployer_pk,
            reactor.functions.configureAndSubscribe(
                BASE_SEPOLIA_CHAIN_ID,
                vault_addr,
                UNICHAIN_SEPOLIA_CHAIN_ID,
                sentinel_addr,
                ai_signer_addr,
            ),
            gas=600_000,
        )
        state["txs"]["configureAndSubscribe"] = tx
        _save_json(deployments_path, state)
        print(f"[Deploy] SynapseReactor configured & subscribed tx={tx}")

    state["deployedUtc"] = datetime.now(timezone.utc).isoformat()
    _save_json(deployments_path, state)

    if not skip_verify:
        state["sourcify"] = verify_all_sourcify(state, settings)
        _save_json(deployments_path, state)

    return state


def verify_all_sourcify(state: dict[str, Any], settings: RuntimeSettings) -> dict[str, Any]:
    from eth_abi import encode as abi_encode

    forge_exe = shutil.which("forge") or r"C:\Users\Wiwit\.foundry\bin\forge.exe"
    reactor_addr = Web3.to_checksum_address(state["lasna"]["SynapseReactor"])
    ai_signer = Web3.to_checksum_address(state["aiSignerAddress"])

    ctor_demo = "0x" + abi_encode(
        ["string", "string", "uint8", "uint256"],
        ["Synapse USD", "sUSD", 18, Web3.to_wei(100_000, "ether")],
    ).hex()
    ctor_vault = "0x" + abi_encode(
        ["address", "address", "address", "uint256"],
        [Web3.to_checksum_address(BASE_CALLBACK_PROXY), reactor_addr, ai_signer, Web3.to_wei(500, "ether")],
    ).hex()
    ctor_sentinel = "0x" + abi_encode(
        ["address", "address"],
        [Web3.to_checksum_address(UNICHAIN_CALLBACK_PROXY), reactor_addr],
    ).hex()

    targets = [
        ("SynapseReactor", LASNA_CHAIN_ID, state["lasna"]["SynapseReactor"], "src/SynapseReactor.sol:SynapseReactor", settings.lasna_rpc_url, ""),
        ("DemoToken", BASE_SEPOLIA_CHAIN_ID, state["baseSepolia"]["DemoToken"], "src/DemoToken.sol:DemoToken", settings.base_rpc_url, ctor_demo),
        ("SynapseGuardVault", BASE_SEPOLIA_CHAIN_ID, state["baseSepolia"]["SynapseGuardVault"], "src/SynapseGuardVault.sol:SynapseGuardVault", settings.base_rpc_url, ctor_vault),
        ("SynapseUnichainSentinel", UNICHAIN_SEPOLIA_CHAIN_ID, state["unichainSepolia"]["SynapseUnichainSentinel"], "src/SynapseUnichainSentinel.sol:SynapseUnichainSentinel", settings.unichain_rpc_url, ctor_sentinel),
    ]
    results: dict[str, Any] = {}
    for label, cid, addr, contract_id, rpc, ctor_args in targets:
        cmd = [
            forge_exe,
            "verify-contract",
            "--verifier",
            "sourcify",
            "--chain",
            str(cid),
            "--rpc-url",
            rpc,
        ]
        if ctor_args:
            cmd.extend(["--constructor-args", ctor_args])
        cmd.extend([addr, contract_id])
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        results[label] = {
            "chainId": cid,
            "address": addr,
            "returncode": proc.returncode,
            "output": (proc.stdout + "\n" + proc.stderr).strip()[:600],
        }
        print(f"[Verify] {label} (chain {cid}) -> rc={proc.returncode}")
    return results


def run_special_adversarial_live_loops(deployments_path: Path = DEPLOYMENTS_PATH, out_path: Path = ARTIFACTS_DIR / "live_special_loops.json") -> dict[str, Any]:
    """Run live testnet proofs for (1) Emergency Freeze -> Unichain Lock -> Unfreeze Sync AND (2) AI-Offline Cron10 Timeout Fallback."""
    settings = RuntimeSettings.from_env()
    deploy = DeploymentConfig.from_file(deployments_path)
    orch = SynapseOrchestrator(settings, deploy)
    deployer_pk = os.getenv("DEPLOYER_PRIVATE_KEY", "")
    actor_addr = Web3.to_checksum_address(deploy.deployer_address)

    # Scenario 1: Emergency Freeze across Base Sepolia + Unichain Sepolia + Governance Unfreeze Sync
    freeze_trace = orch.run_single_live_loop(
        scenario_name="emergency_freeze_unichain_cascade",
        recipient=actor_addr,
        token=deploy.demo_token,
        amount_wei=Web3.to_wei(9500, "ether"),
        anomaly_hint_bps=9400,
        ttl_seconds=120,
        allow_heuristic_fallback=False,
    )

    # Restore vault via governance unfreezeVault() -> Lasna reacts to VaultUnfrozen -> Unichain unlocks!
    uni_blk_before = orch.w3_uni.eth.block_number
    unfreeze_tx = send_contract_tx(orch.w3_base, deployer_pk, orch.vault.functions.unfreezeVault(), gas=180_000)
    uni_unfreeze_tx: str | None = None
    deadline = time.perf_counter() + 120.0
    while time.perf_counter() < deadline:
        ulogs = orch.sentinel.events.UnichainSentinelUnfrozen().get_logs(
            from_block=max(uni_blk_before, orch.w3_uni.eth.block_number - 500),
            to_block=orch.w3_uni.eth.block_number,
        )
        if ulogs:
            uni_unfreeze_tx = "0x" + ulogs[-1]["transactionHash"].hex().lstrip("0x")
            break
        time.sleep(1.5)

    # Scenario 2: AI-Offline Autonomous Cron10 Timeout Fallback (propose with short 22s TTL, do NOT call submitAIVerdict!)
    base_blk = orch.w3_base.eth.block_number
    lasna_blk = orch.w3_lasna.eth.block_number
    propose_timeout_tx = send_contract_tx(
        orch.w3_base,
        deployer_pk,
        orch.vault.functions.proposeIntent(
            actor_addr,
            Web3.to_checksum_address(deploy.demo_token),
            Web3.to_wei(15, "ether"),
            300,
            22,
            Web3.keccak(text="synapseguard:ai_offline_cron_timeout"),
        ),
        gas=300_000,
    )
    rec = orch.w3_base.eth.get_transaction_receipt(propose_timeout_tx)
    plogs = orch.vault.events.IntentProposed().process_receipt(rec)
    timeout_intent_id = int(plogs[0]["args"]["intentId"])
    pickup_ms = orch.wait_for_lasna_pending_intent(timeout_intent_id)
    print(f"[Special] Timeout intent={timeout_intent_id} ingested on Lasna ({pickup_ms:.0f}ms). AI worker intentionally offline; waiting for Cron10...")

    settled_timeout = orch.wait_for_full_loop_settlement(
        intent_id=timeout_intent_id,
        expect_unichain_freeze=False,
        base_from_block=base_blk,
        lasna_from_block=lasna_blk,
        uni_from_block=orch.w3_uni.eth.block_number,
        timeout_sec=180.0,
    )

    result = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "emergency_freeze_loop": freeze_trace.to_dict(),
        "governance_unfreeze_sync": {
            "base_unfreeze_tx": unfreeze_tx,
            "unichain_unfreeze_tx": uni_unfreeze_tx,
            "base_frozen_after": bool(orch.vault.functions.emergencyFrozen().call()),
            "unichain_locked_after": bool(orch.sentinel.functions.emergencyLocked().call()),
        },
        "ai_offline_cron_timeout_loop": {
            "intent_id": timeout_intent_id,
            "origin_propose_tx": propose_timeout_tx,
            "base_settlement_tx": settled_timeout["base_settlement_tx"],
            "lasna_sync_tx": settled_timeout["lasna_sync_tx"],
            "outcome_name": settled_timeout["outcome_name"],
            "lasna_synced": settled_timeout["lasna_synced"],
            "cron_subscribed_after": bool(orch.reactor.functions.cronSubscribed().call()),
        },
    }
    _save_json(out_path, result)
    print(f"[Special] Saved emergency freeze/unfreeze + AI-offline Cron10 timeout proof to {out_path}")
    return result


def _save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="synapse-deploy")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_dep = sub.add_parser("deploy", help="Deploy, fund, configure, and Sourcify-verify across 3 testnets")
    p_dep.add_argument("--deployments", default=str(DEPLOYMENTS_PATH))
    p_dep.add_argument("--skip-verify", action="store_true")

    p_spec = sub.add_parser("special-loops", help="Run live freeze/unfreeze and AI-offline Cron10 timeout loops")
    p_spec.add_argument("--deployments", default=str(DEPLOYMENTS_PATH))
    p_spec.add_argument("--output", default=str(ARTIFACTS_DIR / "live_special_loops.json"))

    args = parser.parse_args(argv)
    if args.cmd == "deploy":
        run_deploy(Path(args.deployments), skip_verify=args.skip_verify)
        return 0
    if args.cmd == "special-loops":
        run_special_adversarial_live_loops(Path(args.deployments), Path(args.output))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
