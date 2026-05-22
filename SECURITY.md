# Security Policy

## Bug bounty

HOTSHOT World runs an active bug bounty on Immunefi:

→ **https://immunefi.com/bug-bounty/hotshot/**

In-scope contracts (this repo, deployed to World Chain):
- `HotshotLaunchpadFactory`
- `BondingCurve`
- `MerkleVestDistributor`
- `LpLocker`
- `Guardian`
- `FeeTreasury`
- `HotshotToken`

Tier rewards (paid from the launch-fee treasury):
- **Critical** (funds drainable, principal lock bypass, allocation manipulation): up to 10% of at-risk funds, capped at $50,000
- **High** (DoS that prevents claims, MEV beyond designed limits): $5,000 – $15,000
- **Medium** (logic error with limited impact, gas griefing): $1,000 – $5,000
- **Low** (informational, non-exploitable): $500 – $1,000

## Out of scope

- The off-chain web app (private repo; report directly to security@hotshot.cool)
- Test contracts under `test/`
- Already-known issues documented in `SECURITY-NOTES.md` (in the app repo) and intentionally accepted residuals (see "Accepted residuals" below)
- Bugs that require compromising a Worldcoin Foundation key or a treasury Safe owner key — those are out-of-scope operational risks, not contract bugs

## Reporting via Immunefi

Use the form on the bounty page. Include:
1. A clear description of the bug
2. A reproducible PoC (Foundry test preferred)
3. Severity classification per the tier list
4. Suggested mitigation

We respond within 72 hours.

## Out-of-band disclosure (if Immunefi is unavailable)

For critical issues only, email `security@hotshot.cool` with the subject
`HOTSHOT critical disclosure`. Encrypt with our PGP key (fingerprint
published at the project README link). We will respond within 24 hours,
acknowledge eligibility for the bounty tier, and coordinate disclosure
timing.

**Please do not file GitHub issues for security vulnerabilities.** They
are public the moment they're filed.

## Audit status

**These contracts have NOT been externally audited.** The risk-management
controls in place instead of an audit are documented in the project's
`OPS-RUNBOOK.md` and `SECURITY-NOTES.md` (both in the app repo). At a
high level:

- 59 forge tests passing including unit, fuzz, invariant, and a
  mainnet-fork test against live Uniswap V3 on World Chain
- Slither static analysis green on `--fail-high`
- Halmos symbolic verification of LpLocker irreversibility (manual
  pre-mainnet gate)
- 72-hour-timelocked Guardian pause for emergency response (cannot mutate
  roots or seize tokens — only pause user-facing entrypoints)
- Low first-launch graduation threshold (2K WLD) + per-buy cap (100 WLD)
  cap financial exposure on the first 5 launches to ~$2-4K per round
- Public open-source ≥ 7 days before first mainnet launch (this repo)
- Immunefi bounty (this page) from day 1

## Accepted residuals

These are known, documented, and intentionally not patched (in this
release):

1. **`npm.increaseLiquidity` on the locked tokenId can dilute the
   treasury fee stream** (UNCX V3.1 has the same property). Anyone can
   add liquidity to our locked position; that liquidity earns a share
   of the fees the treasury would otherwise collect. Fee-griefing only,
   not fund loss.

2. **MEV on the graduation transaction.** Our server signer is not a
   World-ID-verified human, so it cannot use Priority Blockspace for
   Humans (PBH). Graduation txs are subject to ordinary mempool MEV.
   The low first-launch threshold caps the per-launch MEV opportunity
   at ~$100-200.

3. **World Chain L1 governance can upgrade the chain with no on-chain
   timelock** (per L2BEAT). Inherited from the chain, outside our
   control.

4. **Path-A sybil model**: one World ID can be linked to multiple World
   App wallets, so "one wallet, one vote" is not the same as "one
   human, one vote." Documented behavior; mitigated by per-wallet
   economic friction.

5. **The off-chain Vercel deploy pipeline** is part of the trust
   boundary. Compromise of the Vercel project or its Privy server
   wallet could result in malformed launches. The 2-of-3 Privy approver
   quorum on `factory.launch` provides defense-in-depth.
