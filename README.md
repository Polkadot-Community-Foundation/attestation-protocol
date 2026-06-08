> [!WARNING]
> The following is a prototype, reference implementation, and proof-of-concept. This open source code is provided for research, experimentation, and developer education only. This code has not been audited, is actively experimental, and may contain bugs, vulnerabilities, or incomplete features. Use at your own risk.

<div align="center">

# Polkadot Attestation Protocol

</div>

A permissionless protocol for creating, revoking, and verifying attestations. Users register schemas that define data formats, then issue attestations against those schemas, producing verifiable, immutable claims.

## Deploy

The deploy builds the contracts and publishes `SchemaRegistry` + `AttestationService` to a
PolkaVM / `pallet-revive` Asset Hub by submitting native `Revive.instantiate_with_code`
extrinsics (no `eth-rpc` adapter, no Docker; stock Foundry compiles the contracts).

**Prerequisites — both required** (the deploy reads them from the environment / `evm/.env`,
copied from [`evm/.env.example`](evm/.env.example)):

- `MNEMONIC` — a **funded** signing account on the target network (its SS58 account pays the
  fees and storage deposits). The example default is the public dev phrase — **replace it.**
- `GENESIS_HASH` — selects the target network from [`evm/scripts/network.ts`](evm/scripts/network.ts).
  The example defaults to **Summit**
  (`0xf388dc6d6cdf6fb77eac3c4a91f31bc0c8642b142f1a757512ab7849f9f70660`); change it for other
  networks.

This repo pins **bun** (`packageManager`), so use bun:

```bash
$ bun install
$ bun run deploy
```

See [`docs/SUMMIT_DEPLOYMENT.md`](docs/SUMMIT_DEPLOYMENT.md) for the full Summit procedure
(funding model, network selection, `RPC_URL` rehearsal override, and verification).

## Deployments

### Testnets

#### Paseo Next Asset Hub V2

* **SchemaRegistry**: [`0xbe92a66b697dc9bd4a35b1b8e3aead484d2010a7`](https://assethub-paseo.subscan.io/account/0xbe92a66b697dc9bd4a35b1b8e3aead484d2010a7)
* **AttestationService**: [`0x24af868f14605460f6385aae166986cee9800514`](https://assethub-paseo.subscan.io/account/0x24af868f14605460f6385aae166986cee9800514)

#### Paseo Next Asset Hub V1

* **SchemaRegistry**: [`0xb50a0be72877a06b90e093a02db6aa659644ddf3`](https://assethub-paseo.subscan.io/account/0xb50a0be72877a06b90e093a02db6aa659644ddf3)
* **AttestationService**: [`0xff35f0da2de747f800baef2a01b03f51af7d111d`](https://assethub-paseo.subscan.io/account/0xff35f0da2de747f800baef2a01b03f51af7d111d)

## License

Licensed under the [MIT License](LICENSE).

## Security

This is reference and proof-of-concept code. It has not been independently audited. Please follow
the [Parity security policy](https://github.com/paritytech/.github/blob/main/SECURITY.md) for reporting vulnerabilities.
