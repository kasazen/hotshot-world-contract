# HOTSHOT World — Contracts (Foundry)

Bespoke World Chain (OP-Stack, EVM-equivalent) launchpad suite for daily
photo-contest token launches. Per-round winner mints a 1B-supply ERC-20
through a pump.fun-style WLD-quoted bonding curve, atomically graduates
to Uniswap V3 (50% LP burned, 50% locked collect-only), and distributes
claim allocations through a single Merkle distributor with per-role
vesting curves.

## Status

**Production-ready code, not externally audited.** Shipping to mainnet
unaudited with the following risk controls, per the project's
[end-to-end production-readiness plan](../OPS-RUNBOOK.md):

- 59 forge tests green (unit, fuzz, invariant, mainnet-fork against live Uniswap V3 on World Chain)
- Slither static analysis green (no HIGH-severity findings) — see `.github/workflows/contracts-ci.yml`
- LpLocker irreversibility verified by Foundry invariant + intended for Halmos symbolic execution (`test/invariant/LpLockerInvariant.t.sol`)
- 72-hour-timelocked Guardian pause across all user-facing entrypoints
- Per-buy WLD cap (`maxBuyPerTx`) on early launches to prevent flash-loan single-tx graduation
- Low first-launch graduation threshold (2K WLD = ~$2-4K LP exposure per round)
- Open-source ≥ 7 days before first mainnet launch (this repo)
- Immunefi bug bounty active from day 1 (link below)

**Security contact / responsible disclosure:** [Immunefi bounty
program](https://immunefi.com/bug-bounty/hotshot/). For high-severity
issues out of bounty scope: see SECURITY.md.

## Contracts

| File | Role |
|---|---|
| `src/Tokenomics.sol` | Constants library (mirror of off-chain `packages/tokenomics`). |
| `src/HotshotToken.sol` | Fixed 1B / 18-dec ERC-20, non-mintable, minted once to the factory. Carries immutable `metadataURI` binding the off-chain photo + vote-tally commitments to the token contract. |
| `src/BondingCurve.sol` | WLD-quoted virtual-reserve constant-product curve. Decaying anti-snipe fee. Atomic graduation to Uniswap V3 with anti-hijack pre-creation check (`PoolPreExists` revert) that neutralizes the Virtuals Apr-2025 attack class. Optional `maxBuyPerTx` cap. Guardian-gated `buy`/`sell`. |
| `src/LpLocker.sol` | Immutable, non-upgradeable, `collectFees()`-only locker for the treasury 50% LP. Principal locked forever — no `decreaseLiquidity` or `safeTransferFrom` path. |
| `src/MerkleVestDistributor.sol` | Single contract, 3 roots; double-hashed leaves (CVE-2023-34459 safe); per-leaf partial-claim accounting; no EOA/`msg.sender` checks (World App = Safe smart accounts). Guardian-gated `claim`. |
| `src/Guardian.sol` | 72h-timelocked pause + 7d auto-unpause. Safe-multisig only. Cannot mutate roots, seize tokens, or affect already-paid tokens. |
| `src/FeeTreasury.sol` | Sink for curve fees + graduation fee + locker LP fees; Safe-multisig owned (Ownable2Step). |
| `src/HotshotLaunchpadFactory.sol` | CREATE2-deterministic per-contest deploy (idempotent retries). Salt includes the launcher key for squat resistance. Emits enriched `Launch` event with `metadataURI` + `voteTallyHash`. |

## Tokenomics

| Allocation | Tokens | % of supply | Immediate unlock | Vesting |
|---|---|---|---|---|
| Bonding curve | 650,000,000 | 65% | — | — |
| Creator | 157,500,000 | 15.75% | 15% | 60 days linear |
| Backers (voted for winner) | 122,500,000 | 12.25% | 30% | 21 days linear |
| Voters (non-winner) | 70,000,000 | 7.0% | 60% | 7 days linear |
| **Total supply** | **1,000,000,000** | **100%** | | |

Constants are duplicated between `src/Tokenomics.sol` (on-chain) and
`packages/tokenomics` (off-chain TS). The off-chain package is the
source of truth for the app layer; any change to the Solidity library
must be mirrored back. A CI assertion is on the roadmap to enforce this
automatically.

## Setup

```bash
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts \
  Uniswap/v3-core Uniswap/v3-periphery --no-commit
forge build
forge test                                       # 59 tests, ~35s
forge test --match-path test/fork/*              # mainnet fork, ~5s on first run
forge test --match-path test/invariant/*         # ~70s, fuzz invariants
```

### Static + symbolic analysis

```bash
# Slither — static analysis. Run before every contract change.
pip install slither-analyzer solc-select
solc-select install 0.8.28 && solc-select use 0.8.28
slither . --foundry-out-directory out \
  --exclude-informational \
  --exclude naming-convention,solc-version,assembly,low-level-calls,timestamp \
  --fail-high

# Halmos — symbolic execution for LpLocker irreversibility. Pre-mainnet gate.
pip install halmos
# (libz3 native lib required — `brew install z3` on macOS; apt install libz3-dev on Linux)
halmos --contract LpLockerInvariant
```

## Deployment

```bash
# World Chain Sepolia (chainId 4801) — testnet
QUOTE_TOKEN=<sepolia-WLD> POSITION_MANAGER=<sepolia-NPM> \
  TREASURY_OWNER=<sepolia-safe> LAUNCHER=<testnet-EOA> \
  forge script script/DeployHotshotSuite.s.sol \
  --rpc-url worldchain_sepolia --broadcast --verify \
  --private-key $DEPLOYER_PRIVATE_KEY

# World Chain mainnet (chainId 480) — production
# Gated on the mainnet readiness checklist in OPS-RUNBOOK §1.
# Use a Privy server wallet, NOT a raw private key.
```

## Key invariants

Either enforced on-chain or verified by the test suite:

- **Σ allocations == 1B**: curve 650M + rewards 350M (creator 157.5M + backers 122.5M + voters 70M). Asserted in factory.launch (`SplitMismatch`) and in `test/Launchpad.t.sol::test_launchWiresAndSplitsExactly`.
- **No path withdraws principal from the burned LP or the locker.** Verified by `test/invariant/LpLockerInvariant.t.sol` (128K random calls) and intended for Halmos symbolic verification.
- **Distributor: a recipient can never claim more than their leaf `amount`.** Verified by `test/invariant/DistributorInvariant.t.sol::invariant_neverOverDistribute` (128K calls).
- **Claim is callable by anyone but pays the leaf account** (Safe-account safe — no `msg.sender == tx.origin` / `code.length == 0` checks).
- **Graduation is atomic** (create + seed + lock in one tx); `_sqrtPriceX96` computed from curve's terminal price — no `slot0` spot read.
- **Graduation reverts if a V3 pool already exists at the predicted address** (Virtuals Apr-2025 mitigation): asserted in `test/AntiHijack.t.sol`.
- **CREATE2 salt = keccak256(launcher, contestId)**: prevents external squatting of predicted addresses. Verified in `test/AntiHijack.t.sol::test_salt_includesLauncher_distinctAddresses`.
- **No on-chain identity gating anywhere** — tokens are freely tradable by anyone on World Chain. Humanity is established off-chain by the World App wallet itself.
- **Guardian cannot mutate merkle roots, seize tokens, or affect tokens already paid out.** Verified by `test/Guardian.t.sol` (13 tests).

## Files NOT in this public repo

The off-chain web app (Next.js mini-app, lifecycle / score / graduation
crons, vote-signature verification, allocation derivation, claim API)
lives in a separate private repo. The on-chain contracts are entirely
self-contained — auditors and bounty hunters can verify every property
in `SECURITY.md` against this repo alone.

## License

MIT — see [LICENSE](./LICENSE).
