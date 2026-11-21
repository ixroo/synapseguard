"""Canonical EIP-191 verdict digest computation, signing, and recovery matching SynapseTypes.sol."""

from __future__ import annotations

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3


def compute_model_digest(
    model_name: str,
    decision: int,
    risk_score_bps: int,
    rationale: str,
) -> bytes:
    """Compute canonical bytes32 commitment to Gemini model output and rationale hash."""
    rationale_hash = Web3.keccak(text=rationale)
    encoded = abi_encode(
        ["string", "uint8", "uint16", "bytes32"],
        [model_name, int(decision), int(risk_score_bps), rationale_hash],
    )
    return bytes(Web3.keccak(encoded))


def compute_verdict_struct_hash(
    dest_chain_id: int,
    vault_address: str,
    intent_id: int,
    decision: int,
    risk_score_bps: int,
    expiry_ts: int,
    model_digest: bytes,
) -> bytes:
    """Mirror `SynapseTypes.verdictEthSignedHash` pre-prefix abi.encode struct hash."""
    if len(model_digest) != 32:
        raise ValueError(f"model_digest must be 32 bytes, got {len(model_digest)}")
    encoded = abi_encode(
        ["uint256", "address", "uint256", "uint8", "uint16", "uint64", "bytes32"],
        [
            int(dest_chain_id),
            Web3.to_checksum_address(vault_address),
            int(intent_id),
            int(decision),
            int(risk_score_bps),
            int(expiry_ts),
            model_digest,
        ],
    )
    return bytes(Web3.keccak(encoded))


def sign_verdict(
    private_key: str,
    dest_chain_id: int,
    vault_address: str,
    intent_id: int,
    decision: int,
    risk_score_bps: int,
    expiry_ts: int,
    model_digest: bytes,
) -> bytes:
    """Sign an intent verdict with EIP-191 prefix matching OpenZeppelin MessageHashUtils."""
    struct_hash = compute_verdict_struct_hash(
        dest_chain_id=dest_chain_id,
        vault_address=vault_address,
        intent_id=intent_id,
        decision=decision,
        risk_score_bps=risk_score_bps,
        expiry_ts=expiry_ts,
        model_digest=model_digest,
    )
    signable = encode_defunct(primitive=struct_hash)
    signed = Account.sign_message(signable, private_key=private_key)
    return bytes(signed.signature)


def recover_verdict_signer(
    dest_chain_id: int,
    vault_address: str,
    intent_id: int,
    decision: int,
    risk_score_bps: int,
    expiry_ts: int,
    model_digest: bytes,
    signature: bytes,
) -> str:
    """Recover checksummed EIP-191 signer address for local verification."""
    struct_hash = compute_verdict_struct_hash(
        dest_chain_id=dest_chain_id,
        vault_address=vault_address,
        intent_id=intent_id,
        decision=decision,
        risk_score_bps=risk_score_bps,
        expiry_ts=expiry_ts,
        model_digest=model_digest,
    )
    signable = encode_defunct(primitive=struct_hash)
    return Web3.to_checksum_address(Account.recover_message(signable, signature=signature))
