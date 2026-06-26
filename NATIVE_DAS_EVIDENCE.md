# Native DAS Path — BCS + JSON-RPC (no CLI) — EVIDENCE

Status: ENABLED cluster-wide (all 3 nodes), 2026-06-27.
Config: sui.use.native.rpc=true in each node's sui.properties (and in the
durable ~/sui-runtime-config/sui.properties so it survives container recreation).

## What changed
The DAS (SuiDasService.doExecute) branches on cfg.useNativeRpc:
  false -> PtbBuilder (shells out to the `sui` CLI per decision)
  true  -> NativePtbBuilder.evaluate() (builds the 6-step access PTB natively
           via SuiPtbEncoder/BcsEncoder, signs with Ed25519Signer, submits
           through SuiRpcClient JSON-RPC sui_executeTransactionBlock)
The native path was already fully implemented; it was switched off (the flag
defaulted to "false"). Enabling it makes the native path the live access path.

## Result 1 — latency (~2.5-4x faster)
Native GRANTs on rpi3 (v5 package, same NOTIFY as the CLI path):
  digest 8MvwazJbfzvY7LEYAnm8PBAMnrEmwjDQmgcvy8VGoopV   2619 ms
  digest 4yABAnUHmV5XPUSDaJRHC3BfLPLGqjM7vbeGYq4FH5jf   1579 ms
versus the CLI path's ~6000-7000 ms per decision. The native path removes the
per-decision process spawn.

## Result 2 — precise on-chain abort reporting (was "sui CLI exited 1")
On DENY, NativePtbBuilder.evaluate() reads effects.status.error from the
JSON-RPC response and returns the real Move abort. Live, after remove_policy:
  Sui DENY ... err=MoveAbort(.. module "policy", function "evaluate",
                              instruction 14, ..) , 1) in command 3
i.e. E_POLICY_MISSING (code 1) at the policy step — the same code proved via
dev-inspect in POLICY_EVIDENCE.md, now surfaced by the live DAS itself. The
CLI path could only log the opaque "sui CLI exited 1".

## Result 3 — precise errors on other failure modes too
Cross-node check: rpi1/rpi2 running the same NOTIFY with Csensor-001's token
(owned by rpi3) are correctly denied with a precise JSON-RPC error:
  "Transaction was not signed by the correct sender: Object 0xe474652c.. is
   owned by 0x27dacda1.. (rpi3) but given signer is 0xef9c6271.. (rpi1)"
This both (a) confirms all three nodes execute the native path (no CLI), and
(b) demonstrates capability isolation: a node cannot use another node's
CapToken (Sui rejects the signature at the input-object check).

## Paper relevance
Evaluation: native BCS+JSON-RPC vs CLI latency (~2.5x), CLI-free runtime.
Observability: denials now carry the exact on-chain abort code / RPC error,
making the live DAS self-explaining instead of opaque.

## Optional follow-up (batched with next plugin rebuild)
Add an abort-code decoder in SuiDasService mapping the raw
MoveAbort(.. policy .., 1) to the symbolic E_POLICY_MISSING for readable logs.
Source change -> batch with the v6 upgrade / next plugin redeploy.
