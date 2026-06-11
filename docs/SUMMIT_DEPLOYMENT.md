# Deploying to Summit

How to deploy this protocol's two contracts — `SchemaRegistry` and `AttestationService` —
to the **Summit** network (a PolkaVM / `pallet-revive` Asset Hub). Self-contained; the
deeper evidence trail lives in the operator's deployment knowledge base.

> **What you get:** two **ownerless** contracts (no admin, no upgrade, no privileged role for
> the deployer). Deploying `attestation-protocol` is a **prerequisite for `browse`**, which
> consumes the two addresses.

## How the deploy works (so the steps make sense)

- `bun run deploy` → `forge build` then `bun evm/scripts/deploy.ts`.
- It submits **native Substrate extrinsics** via `polkadot-api` — `Revive.map_account()` once,
  then `Revive.instantiate_with_code(...)` twice. **No `eth-rpc` adapter, no Docker.**
- The signer is a **native sr25519 key** from `MNEMONIC`. After `map_account`, revive charges
  the instantiations to the signer's **own `AccountId32`**.
- `forge` is used **only to compile**. **Stock Foundry is correct** — the contracts deploy as
  **EVM bytecode** (verified: the live paseo-next-v2 `SchemaRegistry` holds `0x6080…` EVM
  bytecode on-chain). You do **not** need foundry-polkadot/resolc.
- Addresses are **nonce-based** (no CREATE2/CREATE3): re-running yields new addresses and
  overwrites `evm/deployments/<network>/`.

## Network selection

The deploy picks its network from `GENESIS_HASH` via `evm/scripts/network.ts`. Summit is
already registered:

| Field | Value |
| --- | --- |
| `GENESIS_HASH` | `0xf388dc6d6cdf6fb77eac3c4a91f31bc0c8642b142f1a757512ab7849f9f70660` |
| RPC | `wss://summit-asset-hub-rpc.polkadot.io` |
| EVM chain id | `420420417` · token **SUM**, 10 dp · SS58 prefix **0** |

> `RPC_URL` overrides the endpoint without editing `network.ts` (e.g. to aim a rehearsal at a
> local Chopsticks fork): `GENESIS_HASH=… RPC_URL=ws://localhost:8000 bun run deploy`.

## Steps

1. **Build & test** (proves HEAD is green):
   ```bash
   cd evm && forge build && forge test && bun run typecheck
   ```
2. **Configure** `evm/.env` (copy from `.env.example`). `GENESIS_HASH` already defaults to
   Summit; **you must still replace the `MNEMONIC`** — the example ships the public dev phrase:
   ```bash
   export MNEMONIC="<funded Summit deployer mnemonic>"
   export GENESIS_HASH=0xf388dc6d6cdf6fb77eac3c4a91f31bc0c8642b142f1a757512ab7849f9f70660
   ```
3. **Dry-run first (no funds, no tx).** Confirm both constructors execute on the real runtime
   and see the exact cost:
   ```bash
   GENESIS_HASH=0xf388dc6d6cdf6fb77eac3c4a91f31bc0c8642b142f1a757512ab7849f9f70660 \
   ORIGIN_SS58=<a funded Summit account> bun scripts/dry-run.ts
   ```
   Expect **✔ both constructors execute without revert**. Measured cost on Summit:
   `SchemaRegistry` 0.7645 SUM + `AttestationService` 0.9449 SUM = **≈ 1.71 SUM refundable
   storage deposits** + 0.02 SUM ED + small (non-refundable) gas.
4. **Fund the deployer's SS58 account** (its public key) with SUM on Summit Asset Hub. This
   one account pays `map_account` and both instantiations — **fund the SS58 account itself,
   not any `…EE` fallback** (that fallback model is only for raw secp256k1/eth-origin keys).
   **~3 SUM** is ample headroom (the ~1.71 SUM of deposits is refundable on contract removal).
   - Because the contracts are ownerless, the deployer identity is irrelevant — reusing an
     already-funded, already-mapped account is the simplest path (no separate funding step).
5. **Deploy:**
   ```bash
   bun run deploy
   ```
   Success prints the two addresses and writes repo-root `deployments/summit/`.
6. **Record:** commit `deployments/summit/`; add the two addresses to the Summit
   deployments register; paste them into `browse`'s SDK config (`SCHEMA_REGISTRY`,
   `ATTESTATION_SERVICE`) so the `browse` deploy can proceed.

## Verify after deploying

- **Existence:** both addresses have code on Summit (`Revive.AccountInfoOf(addr)` →
  `account_type: Contract`).
- **Wiring:** `AttestationService` was constructed with the deployed `SchemaRegistry` (it's
  appended as the constructor arg).
- **Ownerless:** there is no owner/admin getter — confirm the contracts expose no privileged
  function (by design).
- **Functional:** register a throwaway schema and read it back (`getSchema(id)`).

## Notes / gotchas

- `1010 Invalid Transaction` ⇒ the deployer's **SS58 account** is unfunded.
- **Dry-run, not Chopsticks, for the instantiation.** Chopsticks' wasm executor traps
  (`unreachable`) running pallet-revive contract execution, so it can rehearse `map_account`
  and signing but **not** the instantiations. Use `bun scripts/dry-run.ts` (step 3) instead —
  it executes both constructors against the real node with no tx/funds.
- There is **no CI** — deployment is a manual operator action (run on the deployer VM).
