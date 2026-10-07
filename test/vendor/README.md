# Pinned test dependencies

These are ordinary Solidity files for offline tests, not submodules. Production
dependencies and remappings are unchanged.

- `v4-core/`: the `test/utils/Deployers.sol` import closure from
  [Uniswap/v4-core at 46c6834698c48bc4a463a86d8420f4eb1d7f3b75](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75),
  matching `docs/dependencies.json`. This includes core's real settlement routers,
  not a replacement PoolManager. Existing production types resolve to `v4-core/`
  in `lib/`; missing test helpers resolve here.
- `solmate/`: `MockERC20.sol` and its ERC20 dependency from
  [transmissions11/solmate at 89365b880c4f3c786bdd453d4b8e8fe410344a69](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69),
  also matching the project's pin. These are required by upstream Deployers;
  the integration tests trade the real Swarmlings token.

Only import paths were rewritten to reuse installed production dependencies and
locate this test-only closure; formatting may follow the repository formatter.
Upstream SPDX headers are retained (including UNLICENSED on core test helpers).
The upstream license files are included alongside the sources.
