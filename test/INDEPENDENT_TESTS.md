# Independent contract tests

The contribution adds tests and test fixtures only. No source, ABI, manifest,
renderer, configuration, or existing contributor test was changed. All dependencies
needed by these tests are ordinary files in `test/vendor/` or the existing `lib/`.

Run `forge build` and `forge test`. To keep generated artifacts in the disposable
scratch directory and prove network independence, use:

```sh
forge build --offline --cache-path test/scratch/cache --out test/scratch/out
forge test --offline --cache-path test/scratch/cache --out test/scratch/out
forge test --offline --cache-path test/scratch/cache --out test/scratch/out \
  --match-test test_whaleExactOutputBuyCrossesOneHundredUnitsGasMeasured -vv
```

## Added coverage

| Suite | Checks |
| --- | --- |
| `IndependentToken.t.sol` | 299,999.99 / 300,000 LING mint/burn boundary; 1,000 fuzz cases at arbitrary unit boundaries; 10% supply funding a Merkle claim fixture; 120,000 LING claim followed by top-up; altered proofs and duplicate claims; contract and 7702-style code-bearing wallets; mixed-owner claim rollback; zero-holder notifications; rejecting recipients; claim reentrancy across transfers and new notifications |
| `IndependentV4.t.sol` | v4-core Deployers, PoolSwapTest and PoolModifyLiquidityTest; all four fee modes and 1,000 fuzz cases; exact trader balances and native refunds; unchanged 12,500 LP fee; fresh token-only manager in both buy modes; boundary buys and sell through routers; 100-unit whale buy with gas logged; pool/distributor/router reward exclusion; empty distribution; zero swap; unfunded/unauthorized settlement rollback; partial fills in all four modes; reentrant/rejecting distribution receiver and successful retry |
| `IndependentConservation.invariant.t.sol` | 256 sequences of depth 96, with unexpected reverts failing the run; five actors including a contract wallet; all four swaps, transfers, NFT transfers, burns, opt-in/out, empty/duplicate claims, notifications, unsolicited ERC-6909 claims, distribution; independent entitlement and fee ledgers; final withdrawal of all whole-wei liabilities |

The pre-existing suites retain constructor/runtime, renderer fallback/staticcall,
permission, maximum collection, NFT-ID reuse, reward-fraction and additional
reentrancy/authorization checks.

The revision extends the existing conservation handler with rejected ETH payments
through four inherited DN404 read selectors. Each selector must remain readable
without ETH and reject a nonzero payment without changing the token's balance.
Random sequences interleave these attempts with swaps, notifications, ownership
changes and claims. A deterministic regression also covers zero active NFTs,
an active holder, the last NFT burning, and full withdrawal of the resulting
holder and treasury liabilities. This independently exercises the accepted
fallback ETH guard; the earlier coverage and accounting oracles are retained.

## Accounting oracles

The hook oracle reads the **PoolManager's Swap event**, which reports raw pool
deltas before hook fees. It calculates the 125 / 10,000 fee independently and
checks user settlements, ERC-6909 claims, LP fee and zero outstanding manager
deltas. Its lifetime ledger includes externally transferred native claims, so
checking `totalFees == distributed + claims` is not merely comparing getters
implemented using that same expression.

The reward reference credits wallets by their NFT counts at each notification.
It never credits a buyer with a previous owner's allocation. Actual claim payments
are measured from recipient balance changes. Notifications with no holders credit
the source-defined treasury fallback. Both whole wei and scaled fractions/dust
are accounted for; no approximate conservation tolerance hides missing ETH.

`owed` is a liability already included in the token's physical ETH balance.
Therefore the requested `claimed + owed + held == notified` uses
`held = token.balance - sum(owed)`: held is uncheckpointed rewards plus dust.
The suite also checks all pending claims against independent entitlements,
solvency, and `token.balance * 1e36 == unpaidScaled + divisionDustScaled`.
After each invariant sequence, all tracked recipients claim and at most six wei
may remain as fractions/division dust.

## Fixture boundaries

- The Merkle distributor is a local test fixture binding index, recipient and
  amount to a sorted-pair proof. No production distributor implementation was
  supplied. The test verifies integration of a funded contract's actual transfer
  with LING/NFT accounting, not a service's root-generation or authorization rules.
- EIP-7702 coverage installs the 23-byte `0xef0100 || delegate` designator and
  exercises code detection and explicit opt-in. Cancun is the pinned EVM; these
  tests do not claim to execute a Prague authorization transaction.
- Reward exclusion covers ordinary ERC20 pool, router and distributor flows.
  Contract wallets that explicitly opt in participate like other NFT owners.
- The whale measurement encloses only the swap router call and includes its
  settlement and 100 NFT mints; pool setup is excluded. It is a local regression
  measurement, not a launch-chain gas estimate.
- No live fork, deployed renderer validation, service admission, or launch
  rehearsal is represented by these offline results.
