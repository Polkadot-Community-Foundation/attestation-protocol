// Dry-run the deploy WITHOUT spending anything: executes both contract
// constructors via the `ReviveApi.instantiate` runtime API against the selected
// network and reports success/revert, gas, storage deposit, and the predicted
// address. No transaction is submitted; no funds move.
//
//   GENESIS_HASH=0xf388... bun scripts/dry-run.ts
//   GENESIS_HASH=0xf388... RPC_URL=ws://localhost:8000 bun scripts/dry-run.ts   # alt endpoint
//   ORIGIN_SS58=5F...     # optional: dry-run from a specific account (defaults to MNEMONIC's)
//
// The origin only needs enough balance to cover the storage-deposit check; the
// contracts are ownerless so the identity is otherwise irrelevant.
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import chalk from "chalk";
import { Binary } from "polkadot-api";
import { encodeAbiParameters, parseAbiParameters } from "viem";

import { connect, getSigner } from "./lib.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT_DIR = path.resolve(__dirname, "../out");

function bytecode(name: string): string {
  const p = path.join(OUT_DIR, `${name}.sol/${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`Missing artifact ${p}. Run \`forge build\` first.`);
  return JSON.parse(fs.readFileSync(p, "utf-8")).bytecode.object as string;
}

function plancksToSum(p: bigint): string {
  return (Number(p) / 1e10).toFixed(6);
}

async function dryOne(api: any, origin: any, name: string, codeHex: string) {
  const res = await api.apis.ReviveApi.instantiate(
    origin,                       // origin: AccountId32
    0n,                           // value
    undefined,                    // gas_limit: None → block limit
    undefined,                    // storage_deposit_limit: None → unlimited
    { type: "Upload", value: Binary.fromHex(codeHex) }, // code: Code::Upload(bytes)
    Binary.fromHex("0x"),         // data
    undefined,                    // salt: None
  );
  const sd = res.storage_deposit;
  const deposit = sd?.type === "Charge" ? (sd.value as bigint) : 0n;
  // `res.result` is a papi Result<InstantiateReturnValue, DispatchError> → {success, value}.
  const ok = res.result?.success === true;
  const val = ok ? res.result.value : undefined;
  const flags = Number(val?.result?.flags ?? 0); // bit0 set = the constructor reverted
  const reverted = (flags & 1) !== 0;
  const addr = val?.addr?.asHex?.();
  const status = !ok
    ? chalk.red(`ERR ${JSON.stringify(res.result?.value)}`)
    : reverted
      ? chalk.red("REVERTED")
      : chalk.green("Ok");
  console.log(
    `  ${name.padEnd(20)} ${status}  ${chalk.dim("storage deposit")} ${plancksToSum(deposit)} SUM`,
  );
  return { ok: ok && !reverted, deposit, addr };
}

async function main() {
  const { client, api, network } = connect();
  const { address } = getSigner();
  // Origin: ORIGIN_SS58 if given, else the configured signer's account. papi's
  // AccountId codec expects an SS58 string (not raw bytes), so use `address`.
  const origin = process.env.ORIGIN_SS58 ?? address;

  console.log();
  console.log(`  ${chalk.bold.cyan("Attestation Protocol")} ${chalk.dim("· dry-run")} ${chalk.dim("(no funds moved)")}`);
  console.log(`  ${chalk.dim("Network ")} ${network.name}   ${chalk.dim("Origin  ")} ${origin}`);
  console.log();

  try {
    const reg = await dryOne(api, origin, "SchemaRegistry", bytecode("SchemaRegistry"));
    // AttestationService takes the registry address; use the predicted one if we got it, else a placeholder.
    const regAddr = (reg.addr ?? "0x" + "11".repeat(20)) as `0x${string}`;
    const ctor = encodeAbiParameters(parseAbiParameters("address"), [regAddr]).replace(/^0x/, "");
    const svc = await dryOne(api, origin, "AttestationService", bytecode("AttestationService") + ctor);

    const ED = 100_000_000n; // 0.01 SUM existential deposit per contract account
    const totalDeposit = reg.deposit + svc.deposit;
    console.log();
    console.log(
      `  ${chalk.bold("Total")}  storage deposits ${chalk.bold(plancksToSum(totalDeposit))} SUM (refundable) + 2×ED ${plancksToSum(2n * ED)} SUM + small gas fees`,
    );
    console.log(
      `  ${reg.ok && svc.ok ? chalk.green("✔ both constructors execute without revert") : chalk.red("✗ a constructor failed — see above")}`,
    );
    console.log();
  } finally {
    client.destroy();
  }
}

main().catch((err) => {
  console.error(chalk.red("\n  Dry-run failed:\n"), err);
  process.exit(1);
});
