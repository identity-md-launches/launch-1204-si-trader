# SITR verification

Run from the repository root:

```sh
forge build
forge test
```

The default suite is entirely offline. Dependencies are ordinary source files under
`test/vendor/`; their versions, source digests and licenses are recorded in
[vendor/UPSTREAM.md](vendor/UPSTREAM.md). No remappings, submodules, configuration
changes, environment writes, RPC URLs or skipped fork tests are required.

| Suite | Coverage |
| --- | --- |
| `SITRToken.t.sol` | Existing contributor tests: constructor supply/metadata, 10%/90% factory transfers, tax direction, dividend exclusions, historical entitlement, claims, registry resolution, forbidden opcodes, and randomized transfers. The two custom fuzz-run overrides were removed to use Foundry's defaults. |
| `SITRTokenEdges.t.sol` | Fee thresholds, maximum circulating buy with one eligible minor unit, returning buyers, fractional checkpoints, claim order, donations, distributor releases, excluded recipients, events, approval replacement/revocation, max/zero failure inputs, registry failures, atomic rollback, and absence of owner/admin functions. |
| `SITRTokenInvariant.t.sol` | A bounded handler makes random buys, sells, delegated transfers, distributor releases, self/zero checkpoints, claims, rejected allowance spends and exits of every eligible holder. Four invariants check conservation, solvency, independent per-holder entitlement, and exclusions. Every sequence ends by paying all holders, including a passive contract. |
| `SITRTokenPoolManager.t.sol` | Actual vendored Uniswap v4 `PoolManager` at the specified mainnet address, with its constructor executed there. Tests single-sided seeding from the deployer's balance, both currency orders, 1.25% pool fees, buys/sells, exact-output swaps, dividend payouts, underpaid settlement rollback, locked/zero-swap failures, and ERC-6909 redemption. |

Fuzz functions use Foundry's default run count (256 in the installed toolchain).
The invariant campaign is limited inline to 64 sequences of 64 actions, with
`fail-on-revert = true`. Only the handler's seven action selectors are targeted;
arbitrary calls to the unrestricted test factory are excluded. Actors and launch
numbers in fixtures are test inputs, not deployment configuration.

The invariant reference model allocates each buy fee directly to every holder in
proportion to its pre-buy balance. It does not read or reproduce SITR's cumulative
index or checkpoints. It preserves 18 fractional decimal places below one token
minor unit, and compares lifetime paid-plus-owed rewards within one minor unit.
For the bounded sequence, total Q128 rounding loss per holder is less than
`64 * 1e27 / 2**128 < 1` minor unit. Escrow accounting is exact: fees plus direct
donations minus paid dividends must equal the token contract's balance. Donated
principal and fees collected with no eligible supply cannot back new rewards.

The integration's paired ERC-20 and factory/trader callbacks are local fixtures;
v4 pricing, liquidity, LP fees, flash accounting and settlement use upstream code.
The paired currency is placed at the brief's address, the opening price is derived
from 2,500 IMD market cap and deployed currency order, and the pool uses fee 12500
and tick spacing 60. The constructor mints the full supply, the factory transfers
10% to the distributor, up to 90% seeds the pool, and liquidity-rounding remainder
goes to the specified burn address. A deliberately underpaid swap must fail with
the real manager's `CurrencyNotSettled` error; the suite checks rollback of token
fees, rewards, balances, pool price, liquidity and fee growth.

This does not validate live Ethereum state, deployed IMD behavior, the external
factory's implementation, its initialization hook, the real Merkle distributor,
or a router's slippage policies. A live fork and the environment-dependent protected
launch harness remain external verification work. These tests require neither and
do not claim to have run them. The launch manifest and root build configuration are
left unchanged.
