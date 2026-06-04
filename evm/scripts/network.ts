/**
 * Network configuration registry keyed by chain genesis hash.
 */

export type NetworkConfig = {
  name: string;
  rpcEndpoints: string[];
};

export const GenesisHashToNetworkConfig: Record<string, NetworkConfig> = {
  "0xd6eec26135305a8ad257a20d003357284c8aa03d0bdb2b357ab0a22371e11ef2": {
    name: "paseo-v1",
    rpcEndpoints: [
      "wss://sys.ibp.network/asset-hub-paseo",
      "wss://asset-hub-paseo.dotters.network",
      "wss://asset-hub-paseo-rpc.dwellir.com",
      "wss://paseo-asset-hub-rpc.polkadot.io",
    ],
  },
  "0x173cea9df45656cf612c8b8ece56e04e9a693c69cfaac47d3628dae735067af8": {
    name: "paseo-v2",
    rpcEndpoints: ["wss://paseo-asset-hub-next-rpc.polkadot.io"],
  },
  "0xf388dc6d6cdf6fb77eac3c4a91f31bc0c8642b142f1a757512ab7849f9f70660": {
    name: "summit",
    rpcEndpoints: ["wss://summit-asset-hub-rpc.polkadot.io"],
  },
};
