import { sr25519CreateDerive } from '@polkadot-labs/hdkd'
import {
  BIP39_EN_WORDLIST,
  DEV_PHRASE,
  entropyToMiniSecret,
  mnemonicToEntropy,
  ss58Encode,
} from '@polkadot-labs/hdkd-helpers'
import { Keccak256 } from '@polkadot-api/substrate-bindings'
import { createClient, FixedSizeBinary } from 'polkadot-api'
import { getPolkadotSigner } from 'polkadot-api/signer'
import { getWsProvider } from 'polkadot-api/ws-provider/node'

import { GenesisHashToNetworkConfig } from './network.ts'

// The EVM (H160) address pallet-revive derives for a Substrate account:
// the last 20 bytes of keccak256(publicKey).
export function evmAddress(publicKey: Uint8Array): Uint8Array {
  return Keccak256(publicKey).slice(12)
}

// True if the account has already been mapped via Revive.map_account.
export async function isAccountMapped(api: any, publicKey: Uint8Array): Promise<boolean> {
  const original = await api.query.Revive.OriginalAccount.getValue(
    FixedSizeBinary.fromBytes(evmAddress(publicKey)),
  )
  return original !== undefined
}

export function requireEnv(name: string, hint?: string): string {
  const value = process.env[name]
  if (!value) {
    console.error(`${name} is required.${hint ? ' ' + hint : ''}`)
    process.exit(1)
  }
  return value
}

function mnemonicToEntropyUnchecked(mnemonic: string): Uint8Array {
  const words = mnemonic.normalize('NFKD').trim().split(/\s+/)
  const bits = words
    .map((w) => {
      const idx = BIP39_EN_WORDLIST.indexOf(w)
      if (idx === -1) throw new Error(`Word "${w}" is not in the BIP39 English wordlist`)
      return idx.toString(2).padStart(11, '0')
    })
    .join('')
  const entropyBits = (words.length * 11 * 32) / 33
  const entropyBinary = bits.slice(0, entropyBits)
  const entropy = new Uint8Array(entropyBits / 8)
  for (let i = 0; i < entropy.length; i++) {
    entropy[i] = parseInt(entropyBinary.slice(i * 8, i * 8 + 8), 2)
  }
  return entropy
}

export function getSigner() {
  const mnemonic = process.env.MNEMONIC ?? DEV_PHRASE
  const derivationPath =
    process.env.DERIVATION_PATH ?? (process.env.MNEMONIC ? '' : '//Alice')

  let entropy: Uint8Array
  try {
    entropy = mnemonicToEntropy(mnemonic)
  } catch {
    console.warn('⚠️  Mnemonic failed BIP39 checksum, proceeding unchecked')
    entropy = mnemonicToEntropyUnchecked(mnemonic)
  }
  const miniSecret = entropyToMiniSecret(entropy)
  const derive = sr25519CreateDerive(miniSecret)
  const keyPair = derive(derivationPath)
  return {
    signer: getPolkadotSigner(keyPair.publicKey, 'Sr25519', keyPair.sign),
    address: ss58Encode(keyPair.publicKey),
    publicKey: keyPair.publicKey as Uint8Array,
  }
}

export function connect() {
  const genesisHash = requireEnv(
    'GENESIS_HASH',
    'Pick from evm/scripts/network.ts.',
  )
  const config = GenesisHashToNetworkConfig[genesisHash]
  if (!config) {
    console.error(
      `No network config for GENESIS_HASH=${genesisHash}. See evm/scripts/network.ts for known networks.`,
    )
    process.exit(1)
  }
  // RPC_URL overrides the registry endpoint without mutating network.ts — e.g.
  // to point a deploy at a local Chopsticks fork (ws://localhost:8000) for a
  // rehearsal. GENESIS_HASH still selects the network config; only the endpoint
  // is swapped.
  const endpoints = process.env.RPC_URL ? [process.env.RPC_URL] : config.rpcEndpoints
  const client = createClient(getWsProvider(endpoints))
  return { client, api: client.getUnsafeApi(), network: config, genesisHash }
}

export async function waitBestBlock(
  tx: any,
  signer: any,
  label: string,
  onStatus?: (status: string) => void,
) {
  return new Promise<any>((resolve, reject) => {
    tx.signSubmitAndWatch(signer).subscribe({
      next: (event: any) => {
        onStatus?.(event.type)
        if (event.type === 'txBestBlocksState' && event.found) {
          if (event.ok) resolve(event)
          else reject(new Error(`${label} failed: ${JSON.stringify(event.dispatchError)}`))
        }
      },
      error: reject,
    })
  })
}
