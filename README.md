# SI TRADER (SITR)

Five original 1024×1024 PNG logo options are in [logos/](logos/README.md), in the requested order: mascot, geometric mark, ticker lettermark, minted badge and illustrative meme. The selected geometric mark is [option 2](logos/logo-2.png).

The root is also a self-contained Foundry project with Solidity 0.8.26, Cancun, optimization and `bytecode_hash = "none"`. It has no library dependencies or unlinked bytecode. All Solidity imports resolve to files in this repository.

## Token and launch

`SITRToken` mints its entire 1,000,000,000-token supply (18 decimals, `1e27` minor units) once to its deployer. There is no further minting, burning, ownership, administration, upgrade mechanism or external transfer callback. Sending tokens to the burn address does not reduce total supply.

`launch.json` records the supplied pool and economics values. The actual launch factory deploys the token with its launch number as the sole constructor argument, resolved from `$launchNumber`. The constructor records `msg.sender` as the immutable factory. The token looks up `distributorOf(uint64)` on that factory because the real Merkle distributor is registered after token creation; the first nonzero result is pinned permanently. No guessed distributor, factory or launch identifier is embedded in production code. The council round in the artwork brief is not treated as the on-chain launch number.

The factory handles the swarm's 10% allocation, 90% pool seed and remainder. The token constructor transfers none of these allocations. A deployment outside the launch factory must supply a compatible registry through its deployer; fee-bearing buys require distributor registration to be available. An unavailable registry, including a reverted call or malformed return data, does not block untaxed transfers or empty claims. A fee-bearing buy instead reverts with `DistributorUnavailable` until the real distributor is registered. There is no token initialization call or setter.

Only transfers from Ethereum's specified Uniswap v4 PoolManager to another address pay 3%, rounded down in token minor units. The manager loses exactly the gross output and the recipient receives the net amount. Transfers to the manager, including seeding and sells, and ordinary wallet transfers are untaxed. A manager self-transfer is untaxed. ERC-6909 balances maintained inside the manager are outside the contract's scope.

Fees remain in the token. The PoolManager, token, burn address and registered distributor earn no dividends. A cumulative per-share index distributes each fee against eligible balances before crediting the buyer's new tokens. An existing buyer can earn on its pre-buy balance. Historical rewards remain with the holder that earned them when balances change. `claim()` pays the caller; `claimFor(holder)` lets anyone trigger payment directly to that holder, including passive contracts. Claimed tokens earn only future fees.

Accounting retains fractional holder credit across transfers and claims. Whole fees collected with no eligible holders are recorded in `unallocatedFees` and are never awarded retroactively to the incoming buyer. Those fees, per-distribution rounding dust and voluntarily deposited tokens remain in the contract with no privileged withdrawal path.

## Deployment parameters and responsibilities

The launch targets Ethereum mainnet. [launch.json](launch.json) contains the exact supplied values:

| Parameter | Value |
| --- | --- |
| Constructor | `SITRToken(uint64 launchNumber_)`, resolved from `$launchNumber` by the launch system |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` (token constant) |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Pool fee / tick spacing | `12500` (1.25%) / `60` |
| Recorded initial price | `125270724187523965593206900` |
| Pool allocation | `9000` basis points of total supply |
| Initial market cap | `2500000000000000000000` IMD minor units (2,500 IMD) |
| Remainder recipient | `0x000000000000000000000000000000000000dead` |

The 1.25% AMM pool fee is separate from SITR's 3% buy transfer fee. The recorded initial price is provenance for SITR as currency0; the factory derives the opening price from the economics and actual deployed currency order.

The launch operator must deploy through the intended registry-bearing factory with the actual launch number. The constructor makes no external calls and requires no other deployed code. The factory must register the actual Merkle distributor before the swarm allocation and trading. Its registry response is trusted at first resolution: the first successful token transfer or claim that observes a valid nonzero address pins it permanently. A view call alone does not pin it. The factory, PoolManager, token and burn address are rejected as distributor values with `InvalidDistributor`. Correct registration is a factory responsibility; SITR has no correction or override function.

The factory sends 100,000,000 SITR to the distributor, seeds up to 900,000,000 SITR into the specified pool and forwards any rounding remainder to the manifest's remainder recipient. It must verify the derived price, currency ordering and settlement before enabling public trading. This repository neither deploys the distributor nor creates or seeds a pool.

After launch, holders use `claimableDividends(holder)`, `claim()` and `claimFor(holder)`; all dividend amounts and payouts are in SITR minor units. No privileged maintenance, funding call or keeper is required. Integrators must account for the net receipt on every ERC-20 PoolManager outflow, including outflows other than swaps, and for dividends paid to the actual token holder (which may be a router or custody contract). The token has no knowledge of individual v4 pool keys or beneficial owners behind contract balances.

## Verification

Run offline with the installed Foundry toolchain and Solidity 0.8.26:

```sh
forge build
forge test
forge fmt --check
```

The 25-test suite covers launch allocation, all reward exclusions, first and returning buyers, third-party and contract-holder claims, fractional credit, transfer/approval failures, absence of privileged calls and forbidden runtime instructions, and exact manager input/output balance deltas. The registry regression tests cover empty, truncated and noncanonical return data, unavailable-registry buy failures, recovery after registration, and invalid distributor rejection without balance changes. The two existing fuzz tests each run 1,000 cases; the stateful test checks conservation and dividend solvency after each of 64 randomized operations per case. This assignment adds only focused deterministic regressions.

The settlement fixture is an offline model of the balance changes required by Uniswap v4, not a full AMM. A live Ethereum fork run and the supplied environment-dependent protected launch harness have not been run here. The protected harness requires the verifier's factory, launch and deployment inputs plus infrastructure contracts absent from this workspace. No RPC, key, transaction broadcast or external dependency is needed by the default suite.
