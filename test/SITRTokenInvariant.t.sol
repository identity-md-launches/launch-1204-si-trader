// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {SITRTestBase} from "./helpers/SITRTestBase.sol";
import {SITRToken} from "../src/SITRToken.sol";

contract InvariantPassiveHolder {}

/// @dev Closed actor set: every token remains in a tracked account. No balance/totalSupply
/// storage edits, mint cheatcodes, or impersonation of the token/burn address are used.
contract SITRHandler is Test {
    SITRToken public immutable token;
    address public immutable distributor;
    address public constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    address[4] public holders;
    uint256 public fees;
    uint256 public donations;
    uint256 public payouts;
    uint256 public unallocated;
    uint256 public buyCalls;
    uint256 public claimCalls;
    uint256 public movementCalls;
    uint256 public rejectedCalls;
    mapping(address => uint256) public paidTo;
    mapping(address => uint256) public idealRewards;
    uint256 private constant PRECISION = 1e18;

    constructor(SITRToken token_, address distributor_) {
        token = token_;
        distributor = distributor_;
        holders = [
            makeAddr("invariant alice"),
            makeAddr("invariant bob"),
            makeAddr("invariant carol"),
            address(new InvariantPassiveHolder())
        ];
    }

    function account(uint256 index) public view returns (address) {
        index %= 8;
        if (index < 4) return holders[index];
        if (index == 4) return distributor;
        if (index == 5) return MANAGER;
        if (index == 6) return BURN;
        return address(token);
    }

    function buy(uint256 toSeed, uint256 amountSeed) external {
        ++buyCalls;
        _move(MANAGER, account(toSeed), _amount(amountSeed, token.balanceOf(MANAGER)), false);
    }

    function sell(uint256 holderSeed, uint256 amountSeed, bool delegated) external {
        address from = holders[holderSeed % 4];
        _move(from, MANAGER, _amount(amountSeed, token.balanceOf(from)), delegated);
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool delegated) external {
        // The distributor can release its allocation; burned and escrowed balances cannot move.
        address from = account(fromSeed % 5);
        _move(from, account(toSeed), _amount(amountSeed, token.balanceOf(from)), delegated);
    }

    function checkpoint(uint256 holderSeed, bool fullSelfTransfer) external {
        address holder = holders[holderSeed % 4];
        _move(holder, holder, fullSelfTransfer ? token.balanceOf(holder) : 0, false);
    }

    function emptyEligibleSupply() external {
        // Exercise transitions through zero eligible supply even while old dividends remain owed.
        for (uint256 i; i < holders.length; ++i) {
            _move(holders[i], MANAGER, token.balanceOf(holders[i]), false);
        }
    }

    function claim(uint256 callerSeed, uint256 holderSeed, bool onBehalf) external {
        ++claimCalls;
        address caller = holders[callerSeed % 3];
        address holder = onBehalf ? account(holderSeed) : caller;
        uint256 beforeHolder = token.balanceOf(holder);
        uint256 beforeCaller = token.balanceOf(caller);
        uint256 beforeEscrow = token.balanceOf(address(token));
        uint256 expected = token.claimableDividends(holder);
        vm.prank(caller);
        uint256 paid = onBehalf ? token.claimFor(holder) : token.claim();
        assertEq(paid, expected, "claim did not pay the available credit");
        payouts += paid;
        paidTo[holder] += paid;
        assertEq(token.balanceOf(holder), beforeHolder + paid, "payment missed the holder");
        assertEq(token.balanceOf(address(token)), beforeEscrow - paid, "escrow debit differs from payout");
        if (caller != holder) assertEq(token.balanceOf(caller), beforeCaller, "caller stole claimFor payment");
        assertEq(token.claimableDividends(holder), 0, "claim can be replayed");
    }

    function rejectUnauthorizedTransfer(uint256 holderSeed, uint256 amountSeed) external {
        ++rejectedCalls;
        address from = holders[holderSeed % 4];
        uint256 requested = _amount(amountSeed, token.balanceOf(from)) + 1;
        vm.prank(from);
        token.approve(address(this), requested - 1);
        uint256 beforeBalance = token.balanceOf(from);
        uint256 beforeOwed = token.claimableDividends(from);
        vm.expectRevert(SITRToken.InsufficientAllowance.selector);
        token.transferFrom(from, MANAGER, requested);
        assertEq(token.balanceOf(from), beforeBalance);
        assertEq(token.claimableDividends(from), beforeOwed);
        assertEq(token.allowance(from, address(this)), requested - 1);
    }

    function _amount(uint256 seed, uint256 available) private pure returns (uint256) {
        // Include exact edges frequently, in addition to amounts across the entire balance.
        uint256 choice = seed % 8;
        if (choice == 0) return 0;
        if (choice == 1) return available;
        if (choice == 2) return available < 1 ? available : 1;
        if (choice == 3) return available < 34 ? available : 34;
        return seed % (available + 1);
    }

    function _move(address from, address to, uint256 amount, bool delegated) private {
        ++movementCalls;
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 fee = from == MANAGER && to != MANAGER ? amount * 3 / 100 : 0;
        if (fee != 0) _distributeIdeal(fee);
        if (to == address(token)) donations += amount - fee;
        if (delegated) {
            vm.prank(from);
            token.approve(address(this), amount);
            assertTrue(token.transferFrom(from, to, amount));
            assertEq(token.allowance(from, address(this)), 0, "gross allowance not spent");
        } else {
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }
        if (from == to) {
            assertEq(token.balanceOf(from), beforeFrom, "self-transfer changed principal");
        } else {
            assertEq(token.balanceOf(from), beforeFrom - amount, "sender debit is not gross amount");
            uint256 received = to == address(token) ? amount : amount - fee;
            assertEq(token.balanceOf(to), beforeTo + received, "recipient receipt differs from expected net");
        }
    }

    function _distributeIdeal(uint256 fee) private {
        fees += fee;
        uint256 eligible;
        for (uint256 i; i < holders.length; ++i) {
            eligible += token.balanceOf(holders[i]);
        }
        if (eligible == 0) {
            unallocated += fee;
            return;
        }
        // Independent per-holder rational allocation. No dividendPerShare/checkpoint reads,
        // and no recreation of the contract's Q128 accumulator. Splitting quotient/remainder
        // avoids intermediate overflow while retaining 18 sub-minor-unit decimal places.
        for (uint256 i; i < holders.length; ++i) {
            uint256 numerator = fee * token.balanceOf(holders[i]);
            idealRewards[holders[i]] += (numerator / eligible) * PRECISION + ((numerator % eligible) * PRECISION)
                / eligible;
        }
    }
}

/// @dev Short campaigns, with Foundry's default fuzz runs unchanged. Unexpected handler reverts
/// fail the suite instead of silently reducing coverage.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SITRTokenInvariantTest is SITRTestBase {
    SITRHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SITRHandler(token, distributor);
        factory.move(token, distributor, SUPPLY / 10);
        for (uint256 i; i < 4; ++i) {
            factory.move(token, handler.holders(i), (i + 1) * 1 ether);
        }
        factory.move(token, MANAGER, SUPPLY * 9 / 10 - 10 ether);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = SITRHandler.buy.selector;
        selectors[1] = SITRHandler.sell.selector;
        selectors[2] = SITRHandler.move.selector;
        selectors[3] = SITRHandler.checkpoint.selector;
        selectors[4] = SITRHandler.claim.selector;
        selectors[5] = SITRHandler.rejectUnauthorizedTransfer.selector;
        selectors[6] = SITRHandler.emptyEligibleSupply.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_SupplyPrincipalAndEligibleSupplyAreConserved() public view {
        uint256 balances;
        uint256 eligible;
        for (uint256 i; i < 8; ++i) {
            uint256 held = token.balanceOf(handler.account(i));
            balances += held;
            if (i < 4) eligible += held;
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(balances, SUPPLY, "principal created or destroyed");
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.eligibleSupply(), eligible, "exclusion denominator is wrong");
    }

    function invariant_EscrowCoversAllDebtsAndOnlyFeesFundDividends() public view {
        uint256 owed;
        uint256 claimed;
        for (uint256 i; i < 4; ++i) {
            address holder = handler.holders(i);
            owed += token.claimableDividends(holder);
            claimed += token.claimedDividends(holder);
        }
        assertEq(token.totalFeesCollected(), handler.fees(), "fee rate or fee direction changed");
        assertEq(token.totalDividendsClaimed(), handler.payouts());
        assertEq(claimed, handler.payouts());
        assertEq(token.unallocatedFees(), handler.unallocated());
        assertEq(token.balanceOf(address(token)), handler.fees() + handler.donations() - handler.payouts());
        assertLe(owed + handler.payouts() + handler.unallocated(), handler.fees(), "dividends exceed allocated fees");
        assertLe(owed + handler.unallocated(), token.balanceOf(address(token)), "dividend escrow insolvent");
    }

    function invariant_EachHolderKeepsExactlyItsEarnedShareAcrossMovesAndClaims() public view {
        for (uint256 i; i < 4; ++i) {
            address holder = handler.holders(i);
            uint256 earned = handler.idealRewards(holder) / 1e18;
            uint256 accounted = token.claimableDividends(holder) + handler.paidTo(holder);
            // At most one minor unit from independent rational vs Q128 flooring. With 64
            // calls and supply 1e27, Q128 distribution loss is < 64e27 / 2**128 < 1 unit.
            assertApproxEqAbs(accounted, earned, 1, "rewards were lost, duplicated, or reassigned");
            assertEq(token.claimedDividends(holder), handler.paidTo(holder));
        }
    }

    function invariant_ExcludedAccountsNeverAccrueRewards() public view {
        for (uint256 i = 4; i < 8; ++i) {
            address excluded = handler.account(i);
            assertTrue(token.isExcludedFromDividends(excluded));
            assertEq(token.claimableDividends(excluded), 0);
            assertEq(token.claimedDividends(excluded), 0);
        }
        assertTrue(token.isExcludedFromDividends(address(0)));
        assertEq(token.swarmDistributor(), distributor);
        assertEq(token.BUY_FEE_BPS(), 300);
    }

    function afterInvariant() public {
        // Settlement remains callable at the end of each random sequence, including for the
        // passive contract. Claiming once must never create a second whole-unit entitlement.
        for (uint256 i; i < 4; ++i) {
            handler.claim(0, i, true);
            assertEq(token.claimFor(handler.holders(i)), 0);
        }
        invariant_SupplyPrincipalAndEligibleSupplyAreConserved();
        invariant_EscrowCoversAllDebtsAndOnlyFeesFundDividends();
        invariant_EachHolderKeepsExactlyItsEarnedShareAcrossMovesAndClaims();
    }

    function test_HandlerExercisesBuySellDelegationDonationsAndClaims() public {
        // Low bits select the general-amount branch rather than the explicit zero edge.
        handler.buy(1, 100 ether + 4);
        handler.move(0, 7, 1 ether + 4, true);
        handler.sell(1, 97 ether + 4, true);
        handler.claim(2, 0, true);
        handler.claim(1, 0, false);
        handler.move(4, 3, 20 ether + 4, false);
        handler.checkpoint(0, true);
        handler.rejectUnauthorizedTransfer(0, 10 ether);
        assertGt(handler.buyCalls(), 0);
        assertGt(handler.claimCalls(), 0);
        assertGt(handler.rejectedCalls(), 0);
        assertGt(handler.fees(), 0);
        assertGt(handler.donations(), 0);
        assertGt(handler.payouts(), 0);
        handler.emptyEligibleSupply();
        assertEq(token.eligibleSupply(), 0);
        handler.buy(0, 100 ether + 4);
        assertGt(handler.unallocated(), 0);
        invariant_SupplyPrincipalAndEligibleSupplyAreConserved();
        invariant_EscrowCoversAllDebtsAndOnlyFeesFundDividends();
        invariant_EachHolderKeepsExactlyItsEarnedShareAcrossMovesAndClaims();
        invariant_ExcludedAccountsNeverAccrueRewards();
        afterInvariant();
    }
}
