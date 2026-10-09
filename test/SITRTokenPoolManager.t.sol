// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {SITRToken} from "../src/SITRToken.sol";
import {V4Actor, V4PairToken} from "./helpers/V4Actors.sol";
import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "./vendor/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "./vendor/v4-core/src/libraries/TransientStateLibrary.sol";

contract SITRTokenPoolManagerTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant SUPPLY = 1_000_000_000e18;
    uint256 private constant OPENING_CAP = 2500 ether;
    uint64 private constant LAUNCH = 73;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant PAIR = address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;
    address private distributor = makeAddr("v4 distributor");
    address private holder = makeAddr("existing v4 holder");
    IPoolManager private manager;
    V4PairToken private pair;
    V4Actor private factory;
    V4Actor private trader;
    SITRToken private token;
    PoolKey private key;
    bool private tokenIsZero;

    function setUp() public {
        // Execute the constructor at the actual address so NoDelegateCall's immutable address
        // and constructor storage both match. Copying deployed runtime alone would invalidate it.
        vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = MANAGER.call("");
        assertTrue(built);
        assertGt(runtime.length, 0);
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        vm.etch(PAIR, address(new V4PairToken()).code);
        pair = V4PairToken(PAIR);
        factory = new V4Actor(manager);
        token = factory.deploy(LAUNCH);
        factory.register(LAUNCH, distributor);
        trader = new V4Actor(manager);
        pair.mint(address(trader), 100 ether);
        _launch();
    }

    function _launch() private {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "constructor pre-distributed supply");
        assertEq(token.balanceOf(distributor), 0);
        factory.move(token, distributor, SUPPLY / 10);
        tokenIsZero = address(token) < PAIR;
        key = PoolKey(
            Currency.wrap(tokenIsZero ? address(token) : PAIR),
            Currency.wrap(tokenIsZero ? PAIR : address(token)),
            12500,
            60,
            IHooks(address(0))
        );
        // Derive sqrt(price) from the opening market cap and deployed currency order.
        uint256 numerator = tokenIsZero ? OPENING_CAP : SUPPLY;
        uint256 denominator = tokenIsZero ? SUPPLY : OPENING_CAP;
        uint160 price = uint160(_sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator)));
        if (tokenIsZero) assertEq(price, 125270724187523965593206900);
        int24 tick = manager.initialize(key, price);
        int24 compressed = tick / 60;
        if (tick < 0 && tick % 60 != 0) --compressed;
        int24 lower = tokenIsZero ? (compressed + 1) * 60 : TickMath.minUsableTick(60);
        int24 upper = tokenIsZero ? TickMath.maxUsableTick(60) : compressed * 60;
        uint256 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint256 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        uint256 allowed = SUPPLY * 9 / 10;
        uint256 liquidity = tokenIsZero
            ? FullMath.mulDiv(allowed, FullMath.mulDiv(sqrtLower, sqrtUpper, 1 << 96), sqrtUpper - sqrtLower)
            : FullMath.mulDiv(allowed, 1 << 96, sqrtUpper - sqrtLower);
        assertLe(liquidity, uint256(type(uint128).max));
        BalanceDelta delta = factory.seed(key, lower, upper, uint128(liquidity));
        uint256 used = uint256(-int256(_tokenDelta(delta)));
        assertGt(used, 0);
        assertLe(used, allowed);
        assertEq(_pairDelta(delta), 0, "seed was not single-sided");
        assertEq(token.balanceOf(MANAGER), used, "pool seed incurred transfer tax");
        assertEq(token.balanceOf(distributor), SUPPLY / 10);
        // Factory forwards any liquidity rounding remainder exactly as the launch economics require.
        factory.move(token, BURN, token.balanceOf(address(factory)));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.eligibleSupply(), 0);
        _assertSettled(address(factory));
    }

    function test_SingleSidedLaunchFirstBuyAndSellSettleAtTheRealManagerAddress() public {
        uint256 reserve = token.balanceOf(MANAGER);
        uint256 pairBefore = pair.balanceOf(address(trader));
        BalanceDelta buyDelta = trader.swap(key, !tokenIsZero, -int256(1 ether), address(trader), false, false);
        uint256 gross = uint256(int256(_tokenDelta(buyDelta)));
        uint256 fee = gross * 3 / 100;
        assertGt(gross, 0);
        assertGt(fee, 0, "swap never exercised transfer fees");
        assertEq(_pairDelta(buyDelta), -int128(1 ether));
        assertEq(pair.balanceOf(address(trader)), pairBefore - 1 ether);
        assertEq(token.balanceOf(address(trader)), gross - fee);
        assertEq(token.balanceOf(MANAGER), reserve - gross);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.unallocatedFees(), fee, "first buyer took its own fee");
        assertEq(token.claimFor(address(trader)), 0);
        _assertSettled(address(trader));

        uint256 sold = token.balanceOf(address(trader));
        BalanceDelta sellDelta = trader.swap(key, tokenIsZero, -int256(sold), address(trader), false, false);
        assertEq(_tokenDelta(sellDelta), -int256(sold), "sell did not settle the gross debt");
        assertGt(_pairDelta(sellDelta), 0);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(MANAGER), reserve - fee);
        assertEq(token.totalFeesCollected(), fee, "sell charged a tax");
        assertEq(token.balanceOf(address(token)), fee);
        assertLt(pair.balanceOf(address(trader)), pairBefore, "round trip ignored AMM fees");
        _assertSettled(address(trader));
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        assertGt(growth0, 0, "AMM input fee was not accounted");
        assertGt(growth1, 0, "reverse swap did not accrue AMM fees");
    }

    function testFuzz_RealSwapRewardsExistingHolderAndAllowsPermissionlessPayout(uint96 input) public {
        vm.prank(distributor);
        token.transfer(holder, 1_000_000 ether);
        uint256 pairInput = bound(input, 1e12, 10 ether);
        BalanceDelta delta = trader.swap(key, !tokenIsZero, -int256(pairInput), address(trader), false, false);
        uint256 gross = uint256(int256(_tokenDelta(delta)));
        uint256 fee = gross * 3 / 100;
        assertGt(fee, 0);
        assertEq(token.balanceOf(address(trader)), gross - fee);
        assertEq(token.claimableDividends(address(trader)), 0);
        assertApproxEqAbs(token.claimableDividends(holder), fee, 1);
        uint256 before = token.balanceOf(holder);
        uint256 payout = token.claimFor(holder);
        assertEq(token.balanceOf(holder), before + payout);
        assertApproxEqAbs(payout, fee, 1);
        assertEq(token.totalFeesCollected(), fee);
        assertEq(token.claimFor(holder), 0);
        assertEq(token.claimableDividends(distributor), 0);
        _assertSettled(address(trader));
    }

    function test_SecondSwapCreditsReturningContractBuyerOnlyOnItsExistingTokens() public {
        vm.prank(distributor);
        token.transfer(holder, 1_000_000 ether);
        trader.swap(key, !tokenIsZero, -int256(1 ether), address(trader), false, false);
        uint256 oldBalance = token.balanceOf(address(trader));
        uint256 eligibleBefore = token.eligibleSupply();
        uint256 feeBefore = token.totalFeesCollected();
        BalanceDelta delta = trader.swap(key, !tokenIsZero, -int256(1 ether), address(trader), false, false);
        uint256 secondFee = uint256(int256(_tokenDelta(delta))) * 3 / 100;
        assertEq(token.totalFeesCollected() - feeBefore, secondFee);
        assertApproxEqAbs(token.claimableDividends(address(trader)), secondFee * oldBalance / eligibleBefore, 1);
        // V4Actor deliberately has no method that calls claim(). Anyone can still pay it.
        assertGt(token.claimFor(address(trader)), 0);
        _assertSettled(address(trader));
    }

    function test_ExactOutputBuyPaysNetOfTransferFeeAndExactOutputSellSettlesWhole() public {
        uint256 wantedGross = 100 ether;
        BalanceDelta buyDelta = trader.swap(key, !tokenIsZero, int256(wantedGross), address(trader), false, false);
        assertEq(_tokenDelta(buyDelta), int256(wantedGross));
        assertEq(token.balanceOf(address(trader)), 97 ether);
        uint256 pairWanted = uint256(-int256(_pairDelta(buyDelta))) / 4;
        BalanceDelta sellDelta = trader.swap(key, tokenIsZero, int256(pairWanted), address(trader), false, false);
        assertEq(_pairDelta(sellDelta), int256(pairWanted));
        assertLt(_tokenDelta(sellDelta), 0);
        assertEq(token.totalFeesCollected(), 3 ether);
        assertEq(token.balanceOf(address(trader)), 97 ether - uint256(-int256(_tokenDelta(sellDelta))));
        _assertSettled(address(trader));
    }

    function test_UnderpaidSellRevertsCurrencyNotSettledAndRollsBackAllState() public {
        trader.swap(key, !tokenIsZero, -int256(1 ether), address(trader), false, false);
        uint256 amount = token.balanceOf(address(trader));
        bytes32 beforeState = _stateHash();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, tokenIsZero, -int256(amount), address(trader), true, false);
        assertEq(_stateHash(), beforeState, "failed settlement changed pool or token state");
        _assertSettled(address(trader));
        trader.swap(key, tokenIsZero, -int256(amount), address(trader), false, false);
        assertEq(token.balanceOf(address(trader)), 0, "valid retry failed after rollback");
    }

    function test_UnderpaidBuyRollsBackTransferTaxAndDividendAccrual() public {
        vm.prank(distributor);
        token.transfer(holder, 1_000_000 ether);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, !tokenIsZero, -int256(1 ether), address(trader), true, false);
        assertEq(_stateHash(), beforeState);
        assertEq(token.claimableDividends(holder), 0);
        _assertSettled(address(trader));
    }

    function test_ZeroSwapAndLockedManagerFailWithoutMovingTokens() public {
        bytes32 beforeState = _stateHash();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swap(key, !tokenIsZero, 0, address(trader), false, false);
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        manager.take(Currency.wrap(address(token)), address(trader), 100 ether);
        assertEq(_stateHash(), beforeState);
        _assertSettled(address(trader));
    }

    function test_InternalERC6909CreditIsUntaxedUntilItBecomesAnERC20Outflow() public {
        uint256 reserve = token.balanceOf(MANAGER);
        BalanceDelta delta = trader.swap(key, !tokenIsZero, -int256(1 ether), address(trader), false, true);
        uint256 gross = uint256(int256(_tokenDelta(delta)));
        Currency currency = Currency.wrap(address(token));
        assertEq(manager.balanceOf(address(trader), currency.toId()), gross);
        assertEq(token.balanceOf(MANAGER), reserve);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.totalFeesCollected(), 0, "internal claims were taxed as ERC20 transfers");
        _assertSettled(address(trader));
        trader.redeem(key, currency, gross, address(trader));
        assertEq(manager.balanceOf(address(trader), currency.toId()), 0);
        assertEq(token.balanceOf(address(trader)), gross - gross * 3 / 100);
        assertEq(token.totalFeesCollected(), gross * 3 / 100);
        assertEq(token.balanceOf(MANAGER), reserve - gross);
        _assertSettled(address(trader));
    }

    function test_SeedBuyAndSellAlsoWorkWithTheOppositeCurrencyOrder() public {
        bool previousOrder = tokenIsZero;
        // CREATE genuine tokens at fresh addresses until the pair ordering flips. No etching of
        // SITR, storage mutation, guessed production address, or fork state is involved.
        bool found;
        for (uint256 i; i < 128; ++i) {
            SITRToken candidate = factory.deploy(LAUNCH);
            if ((address(candidate) < PAIR) != previousOrder) {
                token = candidate;
                found = true;
                break;
            }
        }
        assertTrue(found, "opposite currency ordering fixture exhausted");
        _launch();
        assertTrue(tokenIsZero != previousOrder);
        test_SingleSidedLaunchFirstBuyAndSellSettleAtTheRealManagerAddress();
    }

    function _tokenDelta(BalanceDelta delta) private view returns (int128) {
        return tokenIsZero ? delta.amount0() : delta.amount1();
    }

    function _pairDelta(BalanceDelta delta) private view returns (int128) {
        return tokenIsZero ? delta.amount1() : delta.amount0();
    }

    function _assertSettled(address actor) private view {
        assertEq(manager.getNonzeroDeltaCount(), 0, "outstanding currency debt");
        assertEq(manager.currencyDelta(actor, key.currency0), 0);
        assertEq(manager.currencyDelta(actor, key.currency1), 0);
        assertFalse(manager.isUnlocked(), "manager left unlocked");
    }

    function _stateHash() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                manager.getLiquidity(key.toId()),
                pair.balanceOf(MANAGER),
                pair.balanceOf(address(trader))
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                token.balanceOf(MANAGER),
                token.balanceOf(address(trader)),
                token.balanceOf(address(token)),
                token.totalFeesCollected(),
                token.unallocatedFees(),
                token.dividendPerShare(),
                token.claimableDividends(holder)
            )
        );
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        result = value;
        uint256 next = (value + 1) / 2;
        while (next < result) {
            result = next;
            next = (value / next + next) / 2;
        }
    }
}
