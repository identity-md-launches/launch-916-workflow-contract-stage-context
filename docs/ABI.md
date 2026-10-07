# ABI integration

Generated JSON arrays are in `docs/abi/Swarmlings.json`,
`docs/abi/DN404Mirror.json` and `docs/abi/SwarmlingsHook.json`. Regenerate after
`forge build` using `python3 tools/export_abis.py`, or pass `--check` to detect drift.

| Contract / call | Meaning |
| --- | --- |
| Token `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf` | Standard ERC-20 metadata and raw LING balances (18 decimals) |
| Token `mirrorERC721()` | Immutable paired ERC-721 address |
| Token `UNIT()`, `MAX_NFTS()`, `activeNFTs()` | 300,000e18 per NFT; maximum 3,333; currently materialized NFT count |
| Token `getSkipNFT(account)` | Whether automatic minting on ERC-20 receipts is disabled |
| Token `setSkipNFT(false)` | Opt caller in and materialize NFTs backed by current balance |
| Token `ownedIds(account, begin, end)` | Current owned-array slice `[begin,end)`; end clamps to balance, invalid/reversed slices are empty |
| Token `pending(account, ids)` | Claimable ETH wei: settled owed plus rewards of these owned IDs; deduplicated |
| Token `owed(account)` | Settled ETH wei, survives sales and burns |
| Token `rewardDebt(id)` | Last settled/mint/transfer accumulator for that ID, scaled by 1e36 |
| Token `rewardRemainder(account)` | Earned fraction of one wei, scaled by 1e36; not independently payable |
| Token `accRewardPerNFT()` | Global reward accumulator scaled by 1e36 |
| Token `claim(ids)` | Caller-owned IDs only; settles selected IDs and pays all caller's owed ETH. Empty valid |
| Token `notifyReward()` with value | Public ETH donation / hook notification |
| Token `RENDERER()`, `TREASURY()` | Fixed renderer and zero-active-NFT fallback recipient |
| Mirror `baseERC20()` | The linked LING base; check reciprocal link |
| Mirror `totalSupply`, `balanceOf`, `ownerOf` | Materialized NFT count and ownership |
| Mirror `tokenURI(id)` | Existing ID's exact renderer metadata, or fallback JSON data URI |
| Mirror `approve`, `setApprovalForAll`, `transferFrom`, `safeTransferFrom` | Standard ERC-721 approvals/transfers, also moving UNIT of LING |
| Hook `poolManager()`, `launchPoolSet()`, `launchPool()`, `LING()` | Permanent manager and first native pool binding (`launchPool` is bytes32) |
| Hook `getHookPermissions()` | The v4 permissions struct; flags must be 0x10CC |
| Hook `BUY_FEE_BPS()`, `SELL_FEE_BPS()` | 125 each; fees charged in ETH |
| Hook `MIN_DISTRIBUTE()` | 10000000000000000 wei |
| Hook `pendingFees()`, `distributed()`, `totalFees()` | Outstanding, delivered and lifetime native claims; includes claim donations |
| Hook `distribute()` | Public transaction forwarding all pending claims when minimum met |

Owned-array indices are not token IDs and change on transfers. Fetch pages at a
consistent block for wallet display; refresh before claiming. `pending` reverts
for nonexistent or unowned IDs just as `claim` does. A holder who sold every NFT
should still see `pending(account, [])` and be able to `claim([])`. A wallet need
not include every NFT in a claim. The view includes `owed` once per call, so do
not sum `pending` across pages without removing that repeated component.

Errors include `NotNFTOwner(id)`, `ETHTransferFailed`, `ReentrantCall`,
`OnlyPoolManager`, `UnexpectedUnlock`, `BelowMinimum` and `PartialFill`. DN404 and
core supply their own errors, exposed in the respective compiled ABIs. Core wraps
hook reverts during swaps; integrations should decode the inner hook error too.

Project events are `RewardNotified(sender, amount, activeNFTs)`,
`RewardClaimed(account, amount)`, `LaunchPoolBound(poolId, ling)`,
`FeeCollected(amount)` and `Distributed(amount)`. Standard LING transfers are
emitted by the base and NFT transfers by the mirror. Successful distribution
emits a token reward notification before its hook distribution event.

No NFT metadata should be inferred from reward amounts. The renderer's independent
`logoSVG()` is not part of the token/mirror ABI or called by either accounting path.
