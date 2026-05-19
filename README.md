# HOTSHOT World — Contracts (Foundry)

Bespoke World Chain (EVM, OP-Stack) launchpad suite. Replaces Meteora DBC + DAMM V2 + Jito Merkle Distributor. Design rationale & decisions in `../WORLD-MIGRATION-PLAN.md` §4.

> **Status: skeletons.** Interfaces, state, events, errors and NatSpec reflect the
> locked design. Bodies marked `// TODO(impl)` are intentionally unimplemented and
> revert — fill during Phase 1, then fuzz/invariant test, then external audit
> *before* mainnet.

## Contracts

| File | Role |
|---|---|
| `Tokenomics.sol` | Shared constants (mirror of `packages/tokenomics`). |
| `HotshotToken.sol` | Fixed-supply 1B / 18-dec ERC-20, non-mintable, minted once to the factory. |
| `BondingCurve.sol` | WLD-quoted virtual-reserve constant-product curve; decaying anti-snipe fee; atomic graduation. |
| `LpLocker.sol` | Immutable, non-upgradeable, `collect()`-only locker for the treasury 50% LP (principal locked forever). |
| `MerkleVestDistributor.sol` | Single contract, 3 roots; double-hashed leaves; per-leaf partial-claim accounting; no EOA/`msg.sender` checks (World App = Safe smart accounts). |
| `FeeTreasury.sol` | Sink for curve fees + graduation fee + locker LP fees; Safe-multisig owned. |
| `HotshotLaunchpadFactory.sol` | CREATE2-deterministic per-contest deploy (idempotent retries). |

## Setup

```bash
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts \
  Uniswap/v3-core Uniswap/v3-periphery --no-commit
forge build
forge test
```

## Key invariants (enforced + to be fuzz/invariant-tested)

- Σ allocations == 1B; curve 650M + rewards 350M.
- No path withdraws principal from the burned LP or the locker.
- Distributor: a recipient can never claim more than their leaf `amount`; claim is
  callable by anyone and pays the **leaf account** (Safe-account safe).
- Graduation is atomic (create+seed+lock in one tx); no `slot0` spot used internally.
- No on-chain identity gating anywhere — tokens are freely tradable by anyone.
