# SynapseGuard

> **Bidirectional Verifiable AI &harr; Reactive Omni Treasury Defense**  
> Built for the **Reactive Omni Buildathon — *Reactive Meets AI* Track**

**SynapseGuard** embeds live **Google Gemini (`gemini-flash-lite-latest`) risk intelligence** natively inside an autonomous **3-chain Reactive Network (Omni)** defense loop connecting **Base Sepolia (`84532`)**, **Reactive Lasna (`5318007`)**, and **Unichain Sepolia (`1301`)**.

Every vault intent emitted on Base Sepolia triggers Reactive Lasna, receives a live quantitative + Gemini structured evaluation signed with a domain-separated **EIP-191 ECDSA key**, executes verified callbacks across **Base Sepolia** and **Unichain Sepolia**, and closes the loop by emitting settlement receipts back into Reactive Lasna so cross-chain state never desynchronizes—even under on-chain guardrail rejection or total off-chain AI outage.

---

## Key Protocol Innovations

1. **Bidirectional Closed-Loop Sync (Zero Silent Desync)**
   - Origin `SynapseGuardVault` emits `IntentProposed` &rarr; Lasna `SynapseReactor` tracks `PENDING_AI` &rarr; moves to `AI_DISPATCHED` upon `submitAIVerdict` &rarr; awaits destination `IntentSettled` callback receipt back on Lasna to finalize `SETTLED` (`ReactorStateSynced`).
   - If destination guardrails (`EXCEEDS_ONCHAIN_CAP`, `INSUFFICIENT_VAULT_LIQUIDITY`, `EXPIRED_TIMESTAMP`, `VAULT_ALREADY_FROZEN`) reject an AI-approved intent on Base Sepolia, the callback settles cleanly without reverting (preserving proxy fee accounting) and feeds `OUTCOME_REJECTED_GUARDRAIL` straight back to Lasna.

2. **Lazy `Cron10` Watchdog (AI-Offline Self-Healing at Zero Idle Cost)**
   - `SynapseReactor` subscribes to `Cron10` (`0x0000000000000000000000000000000000fffFfF`) **only when `_activeIntentIds.length` rises from `0` to `1`**, and automatically unsubscribes using the exact 6-argument tuple when all intents settle (`cron_subscribed = false`).
   - If the off-chain Gemini reviewer stops responding past `block.timestamp > deadlineTs`, Lasna `Cron10` dispatches `onTimeoutFallbackCallback` autonomously to Base Sepolia so user intents never deadlock in escrow.

3. **Correlated Multi-Chain Emergency Freeze & Automatic Recovery**
   - `DECISION_FREEZE_EMERGENCY` triggers **two atomic `SYSTEM.requestCallbackV_1_0` dispatches** from Lasna: freezing `SynapseGuardVault` on Base Sepolia (`84532`) and locking `SynapseUnichainSentinel` on Unichain Sepolia (`1301`).
   - Governance calling `unfreezeVault()` on Base Sepolia emits `VaultUnfrozen`, causing Reactive Lasna to dispatch `onCrossChainUnfreeze` to Unichain automatically.

4. **Defense-in-Depth Cryptographic Verification + 200ms Block Compatibility**
   - All TTLs and signature expiries strictly use `block.timestamp` (safe on Base Sepolia's 200ms blocks).
   - Signatures bind `(destChainId, vaultAddress, intentId, decision, riskScoreBps, expiryTs, modelDigest)` via EIP-191 ECDSA (`SynapseTypes.verdictEthSignedHash`) and are verified on **both** Reactive Lasna and Base Sepolia, guarded by `onlyServiceProvider` and `onlyCallbackSender(rc_)`.

---

## Live Verified Deployments (Sourcify Verified `rc=0`)

| Contract | Network | Chain ID | Address | Explorer |
|---|---|---:|---|---|
| `SynapseReactor` | Reactive Lasna | `5318007` | [`0xC2c5A2d58024F985E3060875590b4693d789559B`](https://lasna.reactscan.net/address/0xC2c5A2d58024F985E3060875590b4693d789559B) | Reactscan |
| `SynapseGuardVault` | Base Sepolia | `84532` | [`0x6B81f6C156e6AbdA4040E5534813736d8acf5BEd`](https://sepolia.basescan.org/address/0x6B81f6C156e6AbdA4040E5534813736d8acf5BEd) | Basescan |
| `SynapseUnichainSentinel` | Unichain Sepolia | `1301` | [`0x26D8Cdb8F670f46188270255D58aba211f848b31`](https://sepolia.uniscan.xyz/address/0x26D8Cdb8F670f46188270255D58aba211f848b31) | Uniscan |
| `DemoToken (sUSD)` | Base Sepolia | `84532` | [`0x26D8Cdb8F670f46188270255D58aba211f848b31`](https://sepolia.basescan.org/address/0x26D8Cdb8F670f46188270255D58aba211f848b31) | Basescan |

- Authorized AI Signer: `0x8E0bfff29c87E49815B8bCF95033ea6853854741`
- Reactive MCP Health Check (`get_rc_health`): **`HEALTHY`** (Debt: `0`, Reserves after 20 loops: `0.4864178 lREACT`, `3/3` active origin subscriptions, `0.0/hour` recent reverts).

---

## Verified On-Chain Full-Loop Evidence (20 / 20 Live Loops Synced)

All raw transaction hashes, Gemini rationales, and block numbers are recorded in [`artifacts/`](./artifacts/):
- [`artifacts/deployments.json`](./artifacts/deployments.json)
- [`artifacts/live_benchmark.json`](./artifacts/live_benchmark.json) (18 live Gemini-evaluated loops: `14 APPROVE` [`11 sUSD` + `3 Native ETH`] & `4 REJECT`)
- [`artifacts/live_special_loops.json`](./artifacts/live_special_loops.json) (Dual-chain `FREEZE_EMERGENCY` + Unichain unfreeze cascade + AI-offline `Cron10` timeout recovery)
- [`artifacts/mcp_health.json`](./artifacts/mcp_health.json) & [`artifacts/mcp_traces.json`](./artifacts/mcp_traces.json)

### Benchmark Latency Summary (18 Live Gemini Benchmark Loops)
- **Median End-to-End Multi-Chain + Gemini Loop Latency:** `15,258.05 ms`
- **P95 End-to-End Latency:** `19,237.32 ms`
- **Median Gemini Inference Latency (`gemini-flash-lite-latest`):** `1,682.54 ms`
- **Lasna Round-Trip State Sync Rate:** **`100%` (`all_lasna_synced: true`)**

### Highlighted Origin &rarr; Lasna &rarr; Destination &rarr; Lasna Tx Hashes

| Scenario | Origin Propose (`Base Sepolia`) | Lasna Action (`Lasna`) | Base / Unichain Settlement | Lasna Sync (`ReactorStateSynced`) |
|---|---|---|---|---|
| **Emergency Freeze (Vault + Unichain)** (`intent #1`) | `0xc9aef6b40220ed0962132b418d8b9f807fafbe26fc9cec1eec6f2822f553bec7` | `0x7275a841e395bf2073ba512cde4b9019c5db7fb155141f19b14c94bc8fb3346f` | Base: `0xe966d7b67ebe8918dbda2e5dbe74807493c50a74ed6ee65075e4b901e408df4a`<br>Unichain: `0x8eeacb6f302699791a301ace042c8d341757c6c84815133faf311b7b24bf169f` | `0x9d51cc233a683d9216fc7e7a2e46eaa27bc1d9204d381452f6adeaea77c360c9` |
| **Governance Auto-Unfreeze** | `0x760dd134c84f4d554fc80849db2fb0f2f8281b9519832a6335a0e29ac457d207` | Reactive auto-relay | Unichain Clear: `0x32dbc673c413c92111efc01b57010aa8ab11042a90d12639bb237ed058fa615e` | Restored (`false`/`false`) |
| **AI-Offline `Cron10` Timeout Fallback** (`intent #2`) | `0xca3a0f40843b50692597507f8a6d8e5ce6bc78ba645c2ece0d38bc805f104b09` | Cron10 autonomous trigger | Base `TIMED_OUT`: `0xbbf11a08346fb4e556929144785123c6018135212923b9f6aa67c606434df6ea` | `0x8ec838fe5f5dd3b3fba5022c5a1fd390e6a00a9b2e515d91f7daa9ef9d1ff19c` |
| **Gemini Approve &rarr; Execute** (`intent #3`) | `0xa3864b454b693eb2a00164a9629c67028ebc592374da9d63f450b5fc561fc4b2` | `0x7ab01dce2ebba7fbab1e35f13b94b8441206b7cd1618aaa94fadef778fd89fea` | Base `EXECUTED`: `0x862bdab8b52464bf08e4788b42bdc889e6be6404b334bee114062ecdf82dc8ef` | `0x3b18694c21d38a999d74b96f4e08545387c9f624fe8989c11bc5f72029fcc37c` |
| **Gemini Reject &rarr; Hold** (`intent #17`) | `0xdeef39d07dd1a60911de63121081e273967f64fd1b6fa5e21a275dc81add8176` | `0x49b779b3c78d96cd8634a0c65230260b843d0ae02dd638c0ad48ddca87125518` | Base `REJECTED_BY_AI`: `0x5a24e996b8618ac682c0b54e5f7dcc78fc7270bb9271941721ec5a899fad7eb7` | `0x8584ad33c03c6a49fb1cbf1b4ae787aea38a2bceb6d4cebd4004b0bf9e84c334` |

---

## Repository Layout

```text
synapseguard/
├── src/
│   ├── SynapseTypes.sol            # Shared verdict enums, events & EIP-191 digest helper
│   ├── SynapseGuardVault.sol       # Base Sepolia (84532) Origin & Destination Vault
│   ├── SynapseReactor.sol          # Reactive Lasna (5318007) AbstractReactive coordinator
│   ├── SynapseUnichainSentinel.sol # Unichain Sepolia (1301) correlated circuit breaker
│   └── DemoToken.sol               # Open-faucet testnet ERC-20 collateral (sUSD)
├── test/
│   ├── SynapseGuard.t.sol          # 31 Foundry unit, E2E, adversarial & fuzz tests (3x256 runs)
│   └── mocks/MockReactiveInfra.sol # Reactive SYSTEM & 160-bit arg-rewriting CallbackProxy mock
├── agent/synapse_agent/
│   ├── analyzer.py                 # Quantitative baseline + live Gemini structured risk engine
│   ├── signer.py                   # EIP-191 signing & Foundry cast parity verification
│   ├── orchestrator.py             # Multi-chain Base <-> Lasna <-> Gemini <-> Unichain runner
│   ├── deploy.py                   # Idempotent 3-chain deployer, Sourcify & special-loops suite
│   ├── video_demo.py               # Automated 1280x720 Chromium + ffmpeg walkthrough renderer
│   └── cli.py                      # CLI: snapshot, watch, benchmark, probe-gemini
├── dashboard/index.html            # Standalone live multi-chain telemetry & policy simulator UI
├── artifacts/                      # Verified deployment metadata, 20 live loop logs & MCP proofs
└── ARCHITECTURE.md                 # Protocol design, security guarantees & Reactive integration spec
```

---

## Quickstart & Reproduction

### 1. Run Foundry Contract Tests & Fuzz Invariants (`31 passed`)

```bash
forge build
forge test --no-dynamic-test-linking -vv
```

### 2. Run Python AI Agent Tests (`16 passed`)

```bash
python -m venv .venv
.venv/Scripts/pip install -e ./agent
pytest agent/tests -v
```

### 3. Inspect Live Dashboard Locally

```bash
python -m http.server 8765
# Open http://127.0.0.1:8765/dashboard/index.html
```

### 4. Deploy & Execute Live Multi-Chain Loops

Copy `.env.example` to `.env`, populate testnet keys and `GEMINI_API_KEY`, then:

```bash
python -m synapse_agent.deploy deploy
python -m synapse_agent.deploy special-loops
python -m synapse_agent.cli benchmark --approve-count 14 --reject-count 4
```

---

## License

MIT — see [LICENSE](./LICENSE).
