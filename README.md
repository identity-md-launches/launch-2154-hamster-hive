# Hamster Hive (HAMSTER)

A plain, fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `HamsterHive` (`src/HamsterHive.sol`) |
| `name()` | `Hamster Hive` |
| `symbol()` | `HAMSTER` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 HAMSTER = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, the whole supply to `msg.sender` (the deployer) |
| Constructor arguments | None |
| Owner / admin | None |
| Transfer fee, tax, burn, blocklist, pause | None |

## Behaviour

- The constructor mints `TOTAL_SUPPLY` to `msg.sender` and emits one `Transfer(0x0, deployer, supply)`.
  Nothing else in the contract calls `_mint`, so the supply can never grow after deployment.
- Transfers, approvals and `transferFrom` are the unmodified OpenZeppelin v5.1.0 `ERC20`
  implementation: amounts arrive whole, an infinite allowance is never decremented, and failures
  revert with the ERC-6093 custom errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`, `ERC20InvalidSender`).
- There is no owner, no `Ownable`, no minter role, no pause, no blocklist, no `burn`/`burnFrom`,
  no upgrade path and no `receive`/`fallback`. The deployer has exactly the powers of any other
  holder once the constructor has run.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and no external library
  calls, so the launch can hash and deploy the bytecode as built.

## Assumptions

- "Deployer" means `msg.sender` of the creation transaction. On the launch this is the
  IdentityMD factory, which receives the entire supply and pays it out (swarm share to the
  MerkleDistributor, pool share to the Uniswap v4 PoolManager, remainder to the requester's
  `remainderTo`). The token does not need to exempt any of those addresses because it never takes a
  fee, so it takes no launch addresses as constructor arguments.
- Since the token has no fee and no transfer hooks, the launch flows (distributor transfer, claims,
  single-sided seed, buys and sells through the PoolManager) move exactly the stated amounts.
- The token holds no ETH and no other tokens, and has no business logic beyond ERC-20, so there is
  no reentrancy surface, oracle dependence or price logic to reason about.
- No application contracts are part of this launch (`contracts` in the manifest is empty), so no
  contract here is owned by anyone.

## Deployment parameters

The launch deploys `HamsterHive` from the bytecode built by `forge build` with the pinned
configuration in `foundry.toml`:

| Setting | Value |
| --- | --- |
| `solc` | `0.8.26` |
| `evm_version` | `cancun` |
| `optimizer` / `optimizer_runs` | `true` / `200` |
| `via_ir` | `false` |
| `bytecode_hash` / `cbor_metadata` | `"none"` / `false` (reproducible bytes, no metadata trailer) |
| `ffi` / `fs_permissions` | `false` / none |

Manifest values the manifest step will record (not written here, as the launch requires):

- `token.contract`: `HamsterHive`
- `token.name` / `token.symbol` / `token.decimals`: `Hamster Hive` / `HAMSTER` / `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- `contracts`: `[]`
- Pool and economics come from the launch: pair IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`,
  fee `12500`, tick spacing `60`, `poolBps` 8000, `initialMarketCapWei` 1,500 IMD,
  `remainderTo` `0x12a7aad083cef06fef7c295514b52fc8bc81960d`.

`script/DeployHamsterHive.s.sol` is a reviewable reference deployment for local or test networks
only. Its `deploy()` function takes no configuration and is exercised directly by the tests; `run()`
wraps it in a broadcast. It is not used by the IdentityMD launch, which deploys through its factory.

## After launch

There is nothing to configure. The token has no owner-settable values, no setters and no
privileged functions. No post-launch operational action is required or possible beyond what any
holder can do.

## Operational responsibilities

- **Supply custody at launch.** Whoever deploys the contract holds the whole supply the moment the
  constructor finishes. On the launch that is the factory, which distributes it in the same
  transaction. Anyone deploying this contract elsewhere must treat the deployer key as the key that
  holds all tokens.
- **No recovery path.** Tokens sent to a wrong address or to a contract that cannot move them are
  lost; the contract has no rescue function by design.
- **No upgrade path.** Any change to the token's behaviour needs a new contract and a migration.
- **Explorer verification.** The deployer should verify the source on Etherscan after launch with
  the pinned compiler settings above (`forge verify-contract ... --compiler-version 0.8.26`). This
  belongs to the network's deployer, not to this task.
- **Security review.** Tests passing are not an audit. The contract is a thin wrapper over
  OpenZeppelin's audited `ERC20`, but the launch's own floor tests and an independent adversarial
  review are the gate before release.

## Repository layout

```
foundry.toml                      compiler pins and build settings (root project, as the verifier requires)
src/HamsterHive.sol               the token
script/DeployHamsterHive.s.sol    reference deploy script
test/HamsterHive.t.sol            unit and fuzz tests
lib/forge-std/                    forge-std v1.9.7 (77041d2c), vendored as plain files
lib/openzeppelin-contracts/       OpenZeppelin Contracts v5.1.0 (69c8def5), vendored as plain files
```

Dependencies are vendored as ordinary files, not git submodules, so the project builds offline.
Remappings live in `foundry.toml`.

## Build and test

```
forge build
forge test
forge fmt --check
```

The fuzz tests were also run with the verifier's seed:

```
FOUNDRY_FUZZ_SEED=0x1ad06224a1aaef5592287f57876d056a10a30575d3880becabd0d910e07d2172 forge test
```

### What the tests cover

Success paths: metadata, supply constants, whole supply minted to the deployer (an EOA, a contract
deployer, and the deploy script's function), a single mint `Transfer` event, independence of
separate deployments, transfers (partial, whole, zero, self, chained with no fee), approvals,
`transferFrom`, infinite allowance preservation.

Failure paths: transfer above balance, transfer to the zero address, `transferFrom` above allowance,
without allowance, and above the holder's balance, approving the zero spender, the deployer pulling
from a holder without allowance, 22 common admin selectors (`mint`, `burnFrom`, `pause`,
`blacklist`, `transferOwnership`, `upgradeTo`, ...) from both the deployer and a stranger all
rejected with supply and holder balances unchanged, ETH sent to the token rejected.

Properties: runtime bytecode under the EIP-170 limit and free of `DELEGATECALL`, `CALLCODE` and
`SELFDESTRUCT`; fuzzed transfer, `transferFrom` and chained transfers conserve the total supply.

## Security checklist (eth-security reference)

Items from the pinned reference that apply, and how they are met:

- **Decimals**: fixed at 18 and returned by `decimals()`; stated in the manifest.
- **Access control**: no privileged functions exist; verified by tests.
- **Reentrancy / SafeERC20 / oracles / vault inflation / proxies / delegatecall / EIP-712**: not
  applicable; the contract makes no external calls, holds no assets and has no upgrade mechanism.
- **Input validation**: inherited ERC-20 checks (zero-address sender, receiver, spender).
- **Tooling**: `forge build`, `forge test` (including fuzzing with the verifier's seed) and
  `forge fmt --check` ran. Slither and Mythril were not run; they are not provided on this machine.
- **Open items for the deployer**: explorer verification after launch; independent review.
