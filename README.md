# SI TRADER (SITR)

Five original 1024×1024 PNG logo options are in [logos/](logos/README.md), in the requested order: mascot, geometric mark, ticker lettermark, minted badge and illustrative meme. The chosen wallet image is [artifacts/logo.png](artifacts/logo.png), a copy of option 2. The built-in image-generation tool drew five drafts, one per option; all five are retained. [Artwork provenance and prompts](artifacts/README.md) record the selection and small-size review.

The root is also a self-contained Foundry project with Solidity 0.8.26, Cancun, optimization and `bytecode_hash = "none"`. It has no library dependencies or unlinked bytecode. All Solidity imports resolve to files in this repository.

## Token and launch

`SITRToken` mints its entire 1,000,000,000-token supply (18 decimals, `1e27` minor units) once to its deployer. There is no further minting, burning, ownership, administration, upgrade mechanism or external transfer callback. Sending tokens to the burn address does not reduce total supply.

`launch.json` records the supplied pool and economics values. The actual launch factory deploys the token with its launch number as the sole constructor argument, resolved from `$launchNumber`. The constructor records `msg.sender` as the immutable factory. The token looks up `distributorOf(uint64)` on that factory because the real Merkle distributor is registered after token creation; the first nonzero result is pinned permanently. No guessed distributor, factory or launch identifier is embedded in production code. The council round in the artwork brief is not treated as the on-chain launch number.

The factory handles the swarm's 10% allocation, 90% pool seed and remainder. The token constructor transfers none of these allocations. A deployment outside the launch factory must supply a compatible registry through its deployer; fee-bearing buys require distributor registration to be available. There is no token initialization call or setter.

Only transfers from Ethereum's specified Uniswap v4 PoolManager to another address pay 3%, rounded down in token minor units. The manager loses exactly the gross output and the recipient receives the net amount. Transfers to the manager, including seeding and sells, and ordinary wallet transfers are untaxed. A manager self-transfer is untaxed. ERC-6909 balances maintained inside the manager are outside the contract's scope.

Fees remain in the token. The PoolManager, token, burn address and registered distributor earn no dividends. A cumulative per-share index distributes each fee against eligible balances before crediting the buyer's new tokens. An existing buyer can earn on its pre-buy balance. Historical rewards remain with the holder that earned them when balances change. `claim()` pays the caller; `claimFor(holder)` lets anyone trigger payment directly to that holder, including passive contracts. Claimed tokens earn only future fees.

Accounting retains fractional holder credit across transfers and claims. Whole fees collected with no eligible holders are recorded in `unallocatedFees` and are never awarded retroactively to the incoming buyer. Those fees, per-distribution rounding dust and voluntarily deposited tokens remain in the contract with no privileged withdrawal path.

## Verification

Run offline with the installed Foundry toolchain and Solidity 0.8.26:

```sh
forge build
forge test
```

The 23-test suite covers launch allocation, all reward exclusions, first and returning buyers, third-party and contract-holder claims, fractional credit, transfer/approval failures, absence of privileged calls and forbidden runtime instructions, and exact manager input/output balance deltas. Two fuzz tests each run 1,000 cases; the stateful test checks conservation and dividend solvency after each of 64 randomized operations per case.

The settlement fixture is an offline model of the balance changes required by Uniswap v4, not a full AMM. A live Ethereum fork run and the supplied environment-dependent protected launch harness have not been run here. The protected harness requires the verifier's factory, launch and deployment inputs plus infrastructure contracts absent from this workspace. No RPC, key, transaction broadcast or external dependency is needed by the default suite.

All six delivered PNG paths were checked for square 1024×1024 dimensions, RGB opacity and PNG validity. All five options were inspected at 64 pixels on light and dark backgrounds; the selected image was also inspected as a 32-pixel circle.
