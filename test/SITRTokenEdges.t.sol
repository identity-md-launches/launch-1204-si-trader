// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SITRTestBase} from "./helpers/SITRTestBase.sol";
import {SITRToken} from "../src/SITRToken.sol";

contract SITRTokenEdgesTest is SITRTestBase {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event DividendsDistributed(uint256 fee, uint256 eligibleBalance);
    event DividendClaimed(address indexed holder, uint256 amount);

    function test_BuyAndClaimEventsDescribeTheActualTokenMovements() public {
        _holders(1, 0); // Exact division, so this also covers the smallest eligible supply.
        vm.expectEmit(false, false, false, true, address(token));
        emit DividendsDistributed(3 ether, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(MANAGER, bob, 97 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(MANAGER, address(token), 3 ether);
        _buy(bob, 100 ether);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(token), alice, 3 ether);
        vm.expectEmit(true, false, false, true, address(token));
        emit DividendClaimed(alice, 3 ether);
        vm.prank(carol);
        assertEq(token.claimFor(alice), 3 ether);
        assertEq(token.balanceOf(carol), 0, "claimFor paid the caller");
        assertEq(token.totalFeesCollected(), 3 ether, "claim was taxed");
        vm.recordLogs();
        assertEq(token.claimFor(alice), 0);
        assertEq(vm.getRecordedLogs().length, 0, "empty claim emitted a payment");
    }

    function test_FeeRoundingThresholdsAndZeroBuy() public {
        _holders(1, 0);
        uint256[7] memory amounts = [uint256(0), 1, 33, 34, 66, 67, 100];
        uint256[7] memory fees = [uint256(0), 0, 0, 1, 1, 2, 3];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 received = token.balanceOf(bob);
            uint256 held = token.balanceOf(address(token));
            _buy(bob, amounts[i]);
            assertEq(token.balanceOf(bob) - received, amounts[i] - fees[i]);
            assertEq(token.balanceOf(address(token)) - held, fees[i]);
        }
    }

    function test_NearlyEntireSupplyBuyAndPayoutDoNotOverflow() public {
        _holders(1, 0);
        uint256 gross = SUPPLY - 1;
        uint256 fee = gross * 3 / 100;
        _buy(bob, gross);
        assertEq(token.balanceOf(MANAGER), 0);
        assertEq(token.balanceOf(bob), gross - fee);
        assertEq(token.claimableDividends(bob), 0);
        assertEq(token.claimableDividends(alice), fee);
        vm.prank(alice);
        assertEq(token.claim(), fee);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFuzz_ReturningBuyerUsesOnlyItsPreBuyWeight(uint96 a, uint96 b, uint96 gross) public {
        uint256 aliceWeight = bound(a, 1, SUPPLY / 4);
        uint256 bobWeight = bound(b, 1, SUPPLY / 4);
        _holders(aliceWeight, bobWeight);
        uint256 amount = bound(gross, 0, token.balanceOf(MANAGER));
        uint256 fee = amount * 3 / 100;
        _buy(alice, amount);
        assertEq(token.balanceOf(alice), aliceWeight + amount - fee);
        assertApproxEqAbs(token.claimableDividends(alice), fee * aliceWeight / (aliceWeight + bobWeight), 1);
        assertApproxEqAbs(token.claimableDividends(bob), fee * bobWeight / (aliceWeight + bobWeight), 1);
    }

    function testFuzz_ZeroAndSelfCheckpointsPreserveFractionalRewards(uint32 a, uint32 b, uint16 gross) public {
        _holders(bound(a, 1, 1_000_000), bound(b, 1, 1_000_000));
        uint256 amount = bound(gross, 34, 1_000);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            _buy(BURN, amount);
        }
        uint256 aliceOwed = token.claimableDividends(alice);
        uint256 bobOwed = token.claimableDividends(bob);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        for (uint256 i; i < 8; ++i) {
            _buy(BURN, amount);
            vm.prank(alice);
            token.transfer(bob, 0);
            uint256 balance = token.balanceOf(alice);
            vm.prank(alice);
            token.transfer(alice, balance);
        }
        assertEq(token.claimableDividends(alice), aliceOwed);
        assertEq(token.claimableDividends(bob), bobOwed);
        assertEq(token.claimFor(alice), aliceOwed);
        assertEq(token.claimFor(bob), bobOwed);
    }

    function test_ClaimsCommuteWhenThereIsNoInterveningDistribution() public {
        _holders(17 ether, 29 ether);
        _buy(carol, 100 ether);
        uint256 snapshot = vm.snapshotState();
        token.claimFor(alice);
        token.claimFor(bob);
        bytes32 firstOrder = _accountingHash();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        token.claimFor(bob);
        token.claimFor(alice);
        assertEq(_accountingHash(), firstOrder);
    }

    function test_DonationsDoNotCreateRewardsOrEraseEarnedDividends() public {
        _holders(100 ether, 100 ether);
        _buy(BURN, 100 ether);
        uint256 owed = token.claimableDividends(alice);
        vm.prank(alice);
        token.transfer(address(token), 100 ether);
        assertEq(token.claimableDividends(alice), owed, "donation erased earned rewards");
        assertEq(token.eligibleSupply(), 100 ether);
        assertEq(token.totalFeesCollected(), 3 ether, "donation became a fee");
        _buy(BURN, 100 ether);
        assertEq(token.claimableDividends(alice), owed, "zero-balance donor earned future rewards");
        assertApproxEqAbs(token.claimableDividends(bob), 4.5 ether, 1);
        token.claimFor(alice);
        token.claimFor(bob);
        assertGe(token.balanceOf(address(token)), 100 ether, "donated principal paid as dividends");
    }

    function test_DistributorReleaseCannotCapturePastFees() public {
        factory.move(token, distributor, SUPPLY / 10);
        factory.move(token, alice, 1 ether);
        factory.move(token, MANAGER, SUPPLY * 9 / 10 - 1 ether);
        _buy(BURN, 100 ether);
        vm.prank(distributor);
        token.transfer(bob, SUPPLY / 10);
        assertEq(token.claimableDividends(bob), 0);
        assertEq(token.claimableDividends(distributor), 0);
        uint256 eligible = token.eligibleSupply();
        _buy(BURN, 100 ether);
        assertApproxEqAbs(token.claimableDividends(bob), 3 ether * (SUPPLY / 10) / eligible, 1);
    }

    function test_ExcludedBuyRecipientsStillPayFeesWithoutReceivingRewards() public {
        _holders(1, 0);
        address[3] memory destinations = [distributor, BURN, address(token)];
        for (uint256 i; i < destinations.length; ++i) {
            uint256 beforeBalance = token.balanceOf(destinations[i]);
            _buy(destinations[i], 100 ether);
            uint256 expectedReceipt = destinations[i] == address(token) ? 100 ether : 97 ether;
            assertEq(token.balanceOf(destinations[i]) - beforeBalance, expectedReceipt);
            assertEq(token.claimableDividends(destinations[i]), 0);
            assertEq(token.claimFor(destinations[i]), 0);
        }
        assertEq(token.claimableDividends(alice), 9 ether);
        assertEq(token.claimFor(alice), 9 ether);
        assertEq(token.balanceOf(address(token)), 97 ether, "net donation was distributed as fees");
    }

    function test_ApprovalOverwriteRevocationAndEvent() public {
        _holders(100 ether, 0);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, bob, 7);
        vm.prank(alice);
        assertTrue(token.approve(bob, 7));
        vm.prank(bob);
        token.transferFrom(alice, carol, 7);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(alice);
        token.approve(bob, 0);
        bytes32 beforeState = _accountingHash();
        vm.prank(bob);
        vm.expectRevert(SITRToken.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 1);
        assertEq(_accountingHash(), beforeState);
    }

    function test_ZeroAddressesAndMaxAmountsRevertAtomicallyAfterRewardsAccrue() public {
        _holders(100 ether, 200 ether);
        _buy(carol, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        bytes32 beforeState = _accountingHash();
        vm.prank(alice);
        vm.expectRevert(SITRToken.ZeroAddress.selector);
        token.approve(address(0), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(SITRToken.ZeroAddress.selector);
        token.transfer(address(0), 0);
        vm.prank(bob);
        vm.expectRevert(SITRToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), 1);
        vm.prank(bob);
        vm.expectRevert(SITRToken.ZeroAddress.selector);
        token.transferFrom(address(0), bob, 0);
        vm.prank(alice);
        vm.expectRevert(SITRToken.InsufficientBalance.selector);
        token.transfer(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(SITRToken.InsufficientBalance.selector);
        token.transferFrom(alice, carol, type(uint256).max);
        vm.prank(MANAGER);
        vm.expectRevert(SITRToken.InsufficientBalance.selector);
        token.transfer(carol, type(uint256).max);
        assertEq(_accountingHash(), beforeState, "reverted operation changed rewards or balances");
    }

    function test_TaxedTransferFromRegistryFailureRestoresGrossAllowance() public {
        factory.register(LAUNCH, address(0));
        factory.move(token, MANAGER, SUPPLY / 2);
        vm.prank(MANAGER);
        token.approve(carol, 100 ether);
        bytes32 beforeState = _accountingHash();
        vm.prank(carol);
        vm.expectRevert(SITRToken.DistributorUnavailable.selector);
        token.transferFrom(MANAGER, carol, 100 ether);
        assertEq(_accountingHash(), beforeState);
        factory.register(LAUNCH, distributor);
        vm.prank(carol);
        token.transferFrom(MANAGER, carol, 100 ether);
        assertEq(token.allowance(MANAGER, carol), 0);
        assertEq(token.balanceOf(carol), 97 ether);
    }

    function test_RegistryRevertDoesNotBreakUntaxedTransfersAndPinnedRegistryIsNotCalled() public {
        factory.register(LAUNCH, address(0));
        bytes memory query = abi.encodeWithSignature("distributorOf(uint64)", LAUNCH);
        vm.mockCallRevert(address(factory), query, abi.encodeWithSignature("Error(string)", "registry offline"));
        factory.move(token, alice, 100 ether);
        factory.move(token, MANAGER, 100 ether);
        assertEq(token.swarmDistributor(), address(0));
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.claimFor(alice), 0);
        vm.prank(MANAGER);
        vm.expectRevert(SITRToken.DistributorUnavailable.selector);
        token.transfer(bob, 100 ether);
        vm.clearMockedCalls();
        factory.register(LAUNCH, distributor);
        token.claimFor(alice); // First successful state-changing resolution pins the registry value.
        vm.mockCallRevert(address(factory), query, hex"ffffffff");
        _buy(bob, 100 ether);
        assertEq(token.swarmDistributor(), distributor);
        assertGt(token.claimableDividends(alice), 0);
    }

    function test_LaunchRegistrationsCannotCrossContaminate() public {
        SITRToken second = factory.deploy(LAUNCH + 1);
        factory.register(LAUNCH + 1, carol);
        factory.move(token, bob, 1);
        factory.move(second, bob, 1);
        assertEq(token.launchNumber(), LAUNCH);
        assertEq(second.launchNumber(), LAUNCH + 1);
        assertEq(token.factory(), address(factory));
        assertEq(token.swarmDistributor(), distributor);
        assertEq(second.swarmDistributor(), carol);
        assertFalse(token.isExcludedFromDividends(carol));
        assertFalse(second.isExcludedFromDividends(distributor));
    }

    function test_NeitherFactoryNorStrangerHasAnOwnerOrParameterSetter() public {
        _holders(100 ether, 200 ether);
        _buy(carol, 100 ether);
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[3] = abi.encodeWithSignature("setFee(uint256)", 0);
        calls[4] = abi.encodeWithSignature("setBuyFee(uint256)", 10_000);
        calls[5] = abi.encodeWithSignature("setPoolManager(address)", alice);
        calls[6] = abi.encodeWithSignature("setDistributor(address)", alice);
        calls[7] = abi.encodeWithSignature("excludeFromDividends(address)", alice);
        calls[8] = abi.encodeWithSignature("pause()");
        calls[9] = abi.encodeWithSignature("rescueTokens(address,uint256)", alice, 1 ether);
        calls[10] = abi.encodeWithSignature("initialize(address)", alice);
        calls[11] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", alice, bytes(""));
        bytes32 beforeState = _accountingHash();
        address[2] memory callers = [address(factory), carol];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool success,) = address(token).call(calls[i]);
                assertFalse(success, "unexpected owner/admin entry point");
            }
        }
        assertEq(_accountingHash(), beforeState);
        assertEq(token.BUY_FEE_BPS(), 300);
        assertEq(token.POOL_MANAGER(), MANAGER);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 300 ether, "holder was frozen");
    }
}
