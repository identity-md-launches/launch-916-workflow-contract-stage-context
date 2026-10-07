# Swarmlings — Sepolia contracts

Swarmlings (LING) is a fixed-supply DN404 token and ERC-721 mirror. Every whole
300,000 LING supports one Swarmling, with at most 3,333 NFTs. SwarmlingsHook charges
a fixed **1.25% fee per swap in native ETH**, all for NFT rewards, on top of the IMD
pool's **1.25% LP fee** (1% to the launch payer, 0.25% to IMD): **2.5% nominal total**.
The four fee bases below specify the exact arithmetic, including rounding.

No owner, admin, proxy, pause, upgrade, mint authority, freeze or seizure function
can change these contracts after deployment. The hook keeps no share and has no
treasury. This Sepolia release tests the mechanism before a separate IMD-paired
mainnet version.

## Build and artifacts

```sh
forge build
forge test
forge fmt --check
forge build --sizes
python3 tools/export_abis.py
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer **200** runs, `via_ir = true`
and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are not
enabled. Dependencies are ordinary vendored source files; the build and tests need
no network or environment variables once Foundry and that compiler are installed.
[Dependency revisions](docs/dependencies.json) identify the exact upstream commits.
Third-party source retains its SPDX notices and accompanying licenses.

| Deployable contract | Source | Constructor | Runtime bytes |
| --- | --- | --- | ---: |
| Swarmlings | `src/Swarmlings.sol` | none | 12,146 |
| DN404Mirror | `lib/dn404/src/DN404Mirror.sol` | created internally by Swarmlings | 2,939 |
| SwarmlingsHook | `src/SwarmlingsHook.sol` | `IPoolManager manager` only | 4,012 |

All three are below EIP-170's 24,576-byte limit; the token's 15,867-byte creation
code, including its mirror constructor, also fits EIP-3860. Runtime tests scan all
three for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`, skipping PUSH operands.
ABIs are exported at [docs/abi](docs/abi); [the ABI guide](docs/ABI.md) describes the
site-facing calls. `tools/export_abis.py --check` checks exports against a build.

## Token and mirror

The zero-argument constructor deploys a regular DN404Mirror and calls
`_initializeDN404(1e27, msg.sender, mirror)`. All 1,000,000,000 LING, with 18 decimals,
go to the deployer. No more LING can be minted. NFT materialization and burning do
not change the fungible supply. ERC-20 transfers move exactly the specified amount;
transferring one NFT on the mirror moves exactly 300,000 LING with it.

The last 100,000 LING cannot form another NFT. IDs range from 1 through 3,333 and
can be recycled after burns. Traits stay fixed for each ID even when it is reminted.
DN404 may transfer an existing NFT directly during an ERC-20 transfer instead of
burning and minting. Both paths checkpoint rewards.

Smart-contract wallets get no automatically generated NFTs unless they opt in with
`setSkipNFT(false)`. DN404's initial supply recipient also starts with skip enabled,
including an EOA deployer. The factory, PoolManager, distributor and hook therefore
skip NFTs during normal ERC-20 launch flows. Ordinary EOAs default to opt-in.

This implementation materializes an opted-in caller's supported NFTs immediately
by performing a zero-value self transfer. `setSkipNFT(true)` suppresses subsequent
automatic minting; it leaves existing NFTs intact, and those NFTs still earn rewards.
As in standard DN404, explicit mirror transfers can deliver an NFT to a recipient
regardless of its automatic-mint skip flag. Use `safeTransferFrom` when recipient
acceptance is needed. No token/NFT receiver callback runs on an ordinary ERC-20
transfer. Minting/burning many NFTs is linear in gas: batch large transfers and do
not opt in a wallet holding the entire supply in one transaction without estimating
gas. The full-collection test deliberately uses Foundry's larger test gas budget.

Permit2's upstream default infinite allowance is disabled. All ERC-20 spenders
require an explicit approval. The unmodified mirror exposes upstream marketplace
`owner()` / `pullOwner()` signaling, but its owner is permanently zero because the
base has no owner function. These confer no authority. The ERC20/ERC721 link is
established during construction and cannot be relinked.

## Fixed art dependency

`RENDERER = 0x07C6380C3Aab0208c7cDd76791530c4d2A2d389F` is a constant. The mirror's
`tokenURI(id)` checks the NFT exists, then delegates through the base to exactly
`IRenderer(RENDERER).tokenURI(id)` using STATICCALL. The returned string is unchanged.
Missing renderer code or a renderer revert returns a minimal `data:application/json`
placeholder. Rendering never participates in balances, transfers, fees or rewards.
The token does not call `logoSVG()`; the site may call the renderer directly.

Per the approved renderer specification, it is immutable with no owner, and its
seven traits are Background, Chassis, Head, Visor, Signal, Headgear and Accessory.
It uses `seed = uint256(keccak256(abi.encode(uint256(id), bytes32(SALT), uint8(nonce))))`,
where `SALT = 0x011ecad7d0b8a52e4b5e3edd97a38fa83743a5db7ab4446105af4dd40086eacd`.
Nonce is zero except for a fixed table of 21 IDs, making all 3,333 portraits distinct.
Traits are cosmetic, fixed per ID, and rendered fully onchain. This project does
not reproduce or change the renderer. Tests use mocks at the fixed address; live
renderer code and trait uniqueness remain the service's deployment verification.

## Hook and fee arithmetic

The hook's low 14 address bits must equal **0x10CC**. Its constructor enforces
`Hooks.validateHookPermissions`. Only `afterInitialize`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta` and `afterSwapReturnDelta` are enabled. There is no
`beforeInitialize`. Every callback accepts only the configured PoolManager.

An authorized `afterInitialize` never rejects a PoolKey, queries a currency, or
calls the renderer. The **first** pool with native ETH as currency0 permanently
sets `launchPool` and `LING = currency1`. Later pools initialize normally but pay
no hook fee. The hash binds the whole PoolKey, including fee, spacing and hook.

Let `A = abs(amountSpecified)` and `R0` be core's raw signed currency0 delta before
hook deductions. A negative `amountSpecified` means exact input. Each fee rounds
down to whole wei.

| Trade | Fee, in ETH wei | Returned hook delta | Partial fills |
| --- | --- | --- | --- |
| Exact-input buy (`zeroForOne = true`) | `floor(A * 125 / 10000)` | positive specified beforeSwap delta | require `R0 = amountSpecified + fee` |
| Exact-output sell (`zeroForOne = false`) | `floor(A * 125 / 10000)` | positive specified beforeSwap delta | require `R0 = amountSpecified + fee` |
| Exact-output buy | `floor(abs(R0) * 125 / 10000)` | positive unspecified afterSwap delta | fee on actual ETH |
| Exact-input sell | `floor(abs(R0) * 125 / 10000)` | positive unspecified afterSwap delta | fee on actual ETH |

Thus an exact-input buy of 1 ETH sends 0.9875 ETH into the pool; an exact-output
sell requesting 1 ETH needs 1.0125 ETH of raw pool output. Core applies its LP fee
separately. Before-mode partial fills revert with `PartialFill`, undoing the fee
mint and swap. Safe casts protect int128 return deltas; full-width math handles
the int256 negative endpoint. Trades with an ETH fee base below 80 wei round the
hook fee to zero. There is no LP fee override.

The only external interaction in a swap callback is the explicitly required
`poolManager.mint(address(this), 0, fee)`. There is no ETH push, reward notification,
renderer call, currency transfer or other third-party call there. ERC-6909 claims
work even before the router settles ETH into a fresh, token-only pool. The tests
exercise both buy variants with zero initial native balance on a real PoolManager.

The [configuration record](docs/hook-configuration.json) records the BaseHook-style
design, implemented directly against core interfaces. `access: "none"` expresses
the brief's required absence of access administration rather than a Wizard owner
setting. The ManumissionHook reference informed the fee bases and partial-fill
condition; no ransom, treasury, oracle, buyback or other unrelated mechanism is used.

## Distribution and holder rewards

Anyone may call `distribute()` once `pendingFees() >= 0.01 ether`. It starts its own
PoolManager unlock, authorizes exactly one callback, burns **all** native claims,
takes that ETH, and sends the entire redeemed amount to `LING.notifyReward()`.
It cannot run inside another manager unlock. Reentrancy is rejected. A failure
restores the claims, ETH balances and `distributed` atomically. No keeper payment
is deducted. Balances below the threshold wait for more fees or claim donations.

At every completed operation:

```text
totalFees() == distributed() + poolManager.balanceOf(hook, 0)
```

`totalFees()` derives this lifetime total from settled distribution and outstanding
claims, rather than maintaining a counter that would miss unsolicited ERC-6909
transfers. Native claim donations are included and reach holders in the same way.
The hook never grants claim approvals. `FeeCollected` records swap fees specifically.

`notifyReward()` is payable and permissionless; donations are welcome. With active
NFTs, `accRewardPerNFT += msg.value * 1e36 / activeNFTs`. Only materialized NFTs
count, including those whose owner subsequently sets skip true. Minted NFTs start
at the current accumulator. Each transfer/burn settles the old owner's entitlement
to `owed[oldOwner]` and resets the ID's debt. The DN404 hook runs after internal
ownership updates using the supplied previous owners, before any ERC-721 receiver
can run. It makes no external calls. A seller below one unit retains earned ETH,
and a buyer never receives an ID's already-notified rewards.

Rewards become earned **when notifyReward executes**, including notifications from
`distribute`, not when the earlier swaps occurred. There is no holding-duration
requirement or historical allocation of still-pending hook claims. Someone acquiring
NFTs just before distribution participates in that distribution; this follows the
specified current-holder accumulator and is not a time-weighted reward system.

If there are no active NFTs, the full payment becomes `owed[TREASURY]`, where
`TREASURY = 0x92cEf4823119f3332A85A39023eEbA01a06890c4` is the requester's intended
wallet. It is used only for this fallback, grants no role, and receives no push.
TREASURY withdraws with `claim([])`, as does a previous holder with burned NFTs.

`claim(ids)` settles only caller-owned IDs, zeros the caller's owed amount, and
pays that caller via checked ETH call under a reentrancy guard. Empty arrays are
valid; duplicate IDs never multiply rewards. A failed payment reverts settlement
and leaves other wallets unaffected. Fractions of a wei are retained per **wallet**
in `rewardRemainder`, including on burns, so repeated settlement cannot discard
earned fractions or transfer them to a buyer. The mandated accumulator division
can leave sub-wei scaled dust per notification; wei rounding may leave ETH in the
token until fractions become claimable. The hook still forwards every redeemed wei.

Use `notifyReward` to send donations. Plain ETH sends to the token and hook are
rejected (except PoolManager's redemption to the hook). Forced ETH is outside the
claim/reward ledger and there is no rescue authority or sweep function.

## Deployment and operations handoff

1. The service supplies Sepolia's actual PoolManager constructor argument. Neither
   source nor tooling hardcodes a PoolManager. The separate manifest writer should
   encode the hook argument as `"$poolManager"`, token arguments as `[]`, flags as
   `0x10CC`, native ETH currency0, LING currency1, and pool LP fee 12500. Initial
   price, tick spacing, liquidity range, launch splits and recipients are service
   inputs governed by the approved launch policy; unit tests use spacing 60 and
   a synthetic price only as fixtures.
2. Mine CREATE2 against the exact creation code plus the encoded manager and the
   actual deployment address/salt scheme. The hook must match all 14 permission
   bits, including unset bits. `test/helpers/HookDeployer.sol` is a local example,
   not a production deployment transaction.
3. **Deploy token, deploy hook and initialize the intended ETH/LING pool atomically.**
   The first-native-pool rule deliberately has no caller/pool allowlist. Splitting
   hook deployment and initialization permits someone else to bind another pool,
   which cannot be repaired. The initialization callback prevents initializing the
   predicted pool while the hook has no code. Confirm the deployed `launchPool`,
   `LING`, mirror link, supply, permissions and runtime bytes before opening use.
4. Verify the fixed renderer on Sepolia and rehearsal behavior with that chain's
   manager and router. Publish/attest source, create the separate canonical
   `launch.json`, obtain independent review, admit and deploy through the services.
   Policy and signed artifact linkage belong to those services. This source
   assignment writes no launch manifest, sends no transactions, and handles no keys.
5. Operators/site users monitor `pendingFees` and call permissionless distribution
   when useful; no scheduled keeper or caller incentive is built into the hook.
   Holders claim their own ETH. The frontend reads live deployed addresses and
   links users to a buy venue; implementing swaps in the site is outside this stage.

The manager is an external dependency with its own protocol administration. It
does not give an administrator control over LING, holder rewards or the hook's
fixed rules. Replacing the manager, token binding, renderer or fallback wallet
requires deploying a different project.

## Validation and review boundaries

Tests cover supply, exact transfers/approvals, skip behavior, all 3,333 IDs, burns
and ID reuse, both NFT transfer paths, safe receiver callbacks, fractional rewards,
duplicate/non-owned claims, rejecting and reentrant claim receivers, renderer
success/absence/revert/STATICCALL enforcement, hook address validation, callback
authorization, pool binding, four swap modes, two partial-fill policies, zero-ETH
startup, claim donations, threshold boundaries, failed distribution rollback and
distribution reentrancy. Two fuzz tests run 256 cases each.

A stateful invariant suite runs 64 sequences of depth 64, requiring no unexpected
reverts. An independent test ledger credits each wallet by its NFT count at each
notification, with no reference to production rewardDebt/owed. Random transfers,
burns, mints, opt-ins, swaps, distributions, donations and claims must preserve
reference entitlements, fixed supply, NFT backing, the fee ledger and ETH conservation.

The supplied Uniswap v4 security, Pashov, ETH security and standards references
were applied locally to permissions, external boundaries, integer limits,
delta signs, rounding, ownership transitions and reentrancy. This is developer
self-review, not the workflow's independent security review. No live fork rehearsal,
Slither, Mythril, formal verification or independent renderer audit was performed.
Those service/review outcomes are not claimed by the local test results.
