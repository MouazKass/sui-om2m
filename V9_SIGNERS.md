# v9 upgrade signers

## 0. The signer set now (2026-11-10): 3 of 5, on five machines

| Label | Where the key lives | How it signs |
|---|---|---|
| publisher | WSL on Mouaz's laptop (the publisher key) | `sui keytool sign` in WSL |
| rpi1, rpi3, rpi4, rpi5 | a dedicated upgrade key generated ON that Pi, `/home/user/.sui-upgrade/upgrade.keystore` (0600), separate from its node key | `scripts/v9/upgrade_signer.sh sign <node> <tx.b64>`: signs inside a `docker run --network none` container, returns only the signature |

Any 3 can upgrade; 2 cannot (rehearsed live, ROLLOUT_V9.md "UpgradeCap multisig").
Addresses and public keys: `deploy/v9/multisig.env` and the ROLLOUT_V9.md table.
One command runs a whole upgrade: `scripts/v9/upgrade_multisig.sh <3 labels>`.

Operator commands (Git Bash on the laptop):

```bash
scripts/v9/upgrade_signer.sh pubkey rpi3              # address + public key of rpi3's upgrade key
scripts/v9/upgrade_signer.sh show   rpi3 upgrade.tx.b64   # decode the tx ON the Pi before signing
scripts/v9/upgrade_signer.sh sign   rpi3 upgrade.tx.b64   # -> suiSignature (only output)
```

There is no mnemonic backup for a Pi key on purpose: a dead Pi or SD card is
handled like a lost key (section 5): three remaining signers move the UpgradeCap
to a new multisig (`00_multisig.sh` with the new key set, then a 3-signed
`sui client transfer` of the cap).

**Replacing a machine signer with a person** (e.g. Hamza): they follow sections
1–4 below on their own machine, send their public key, and the set is re-derived
with `00_multisig.sh -t 3 -l "<labels>" <pks...>` and the cap moved with 3 signatures.
Their signature is passed to the upgrade as `SIG_<label>=...`.

---

## For a human signer: what you need to do

You have been asked to be one of the signers for the sui-om2m Move package on Sui
**testnet**. Upgrades need a majority of the signers (3 of 5 today), so no single
person or machine can change the contract alone. This section is everything you
need. It takes about 10 minutes now and about 2 minutes per upgrade later.

**The one rule: never send your private key, mnemonic or `.keystore` file to
anyone, including Mouaz.** You only ever send a *public key* (now) and a
*signature* (later). Both are safe to paste into chat or email.

## 1. Install the Sui CLI (once)

You need **`testnet-v1.83.1` or newer**. Older CLIs cannot talk to testnet.

- Linux / WSL / macOS: download `sui-testnet-v1.83.1-<your-os>.tgz` from
  <https://github.com/MystenLabs/sui/releases/tag/testnet-v1.83.1>, check its
  SHA-256 against the digest shown on that page, then unpack it:
  ```bash
  tar xzf sui-testnet-v1.83.1-ubuntu-x86_64.tgz && ./sui --version   # sui 1.83.1-...
  ```
- Windows: the same, with the `windows-x86_64` archive.

You don't need any SUI, and you don't need to connect to a network for steps 2 and 4.

## 2. Make a signing key (once)

```bash
sui keytool generate ed25519
```

This prints a `suiAddress`, a `publicBase64Key`, and a 12-word `mnemonic`.
It also writes a `<address>.key` file into the current folder.

- **Write the 12 words on paper** and keep them offline. They are the key. If
  they are lost, you can no longer sign.
- Import the key into your local keystore so `sign` can find it:
  ```bash
  sui keytool import "<your 12 words>" ed25519
  ```
  Then delete the `<address>.key` file, which holds the same private key.
- Use a machine that only you control, and not the same machine as another
  signer. Two signers on one laptop would make it 1-of-2 in practice.

## 3. Send your public key (once)

Send Mouaz **only** the `publicBase64Key` line. It is 44 characters, starts
with `A` (the ed25519 flag), and looks like this:

```
publicBase64Key: AN1Ild...XdtW        <- send this
```

You can print it again at any time:

```bash
sui keytool list          # copy the publicBase64Key column for your address
```

Do not send the mnemonic, the `.key` file, `sui.keystore`, or anything that
says `suiprivkey`.

Mouaz combines the public keys into one shared multisig address
(`scripts/v9/00_multisig.sh`). You can check that address yourself, because
it is derived from public data only (the keys in `deploy/v9/multisig.env`, in that order):

```bash
sui keytool multi-sig-address --pks <PK1> <PK2> <PK3> <PK4> <PK5> --weights 1 1 1 1 1 --threshold 3
```

## 4. Sign an upgrade (each time)

You'll receive a file called `upgrade.tx.b64`. It holds the unsigned
transaction bytes. Before signing, look at what you are signing:

```bash
sui keytool decode-or-verify-tx --tx-bytes "$(cat upgrade.tx.b64)"
```

Check that:
- the **sender** is the multisig address from step 3;
- the command is an **Upgrade** using the package's UpgradeCap
  (`0xba61b4fb…c3d2`);
- the git commit you were told it was built from matches the one you reviewed.

If it looks right, sign it:

```bash
sui keytool sign --address <your-suiAddress> --data "$(cat upgrade.tx.b64)"
```

Send back **only** the `suiSignature` value. It is 132 Base64 characters
starting with `A`. The order the signers reply in doesn't matter.
`02_upgrade.sh combine` sorts the signatures into key order, and it rejects a
signature from a key that isn't a member.

A signature covers those exact bytes only. It can't be reused for a different
transaction, and if the transaction is rebuilt, for example after a gas coin
changed, you'll be asked to sign the new file.

## 5. If something goes wrong

- **Lost key (mnemonic gone):** tell Mouaz. While three other signers still
  have their keys, they can move the UpgradeCap to a new multisig that uses
  your new key.
- **Key possibly exposed:** tell Mouaz straight away. The fix is the same as
  for a lost key. One exposed key alone can't upgrade anything; it takes three.
- **Asked to sign something you don't recognise:** don't sign it. Ask first.

---

Background, for the curious: `V9_DESIGN.md` §5 explains the design. The v9
upgrade adds k-of-n governance (`quorum.move`), so once it is armed, no single
node can revoke another node's trust capability either.
