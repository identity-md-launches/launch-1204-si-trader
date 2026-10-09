// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SITRToken} from "../src/SITRToken.sol";

interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes4 selector) external;
    function etch(address target, bytes calldata code) external;
}

/// @dev Test-only launch factory. Production resolves the real factory's registry.
contract FactoryFixture {
    mapping(uint64 => address) public distributorOf;

    function deploy(uint64 launchNumber) external returns (SITRToken) {
        return new SITRToken(launchNumber);
    }

    function register(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(SITRToken token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/// @dev Offline model of the balance-delta settlement that SITR must preserve in v4.
/// It is deliberately not a pool pricing model or a substitute for a live fork run.
contract SettlementFixture {
    function settleInput(SITRToken token, uint256 amount) external {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amount);
        require(token.balanceOf(address(this)) - beforeBalance == amount, "CurrencyNotSettled");
    }

    function takeOutput(SITRToken token, address recipient, uint256 amount) external {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.transfer(recipient, amount);
        require(beforeBalance - token.balanceOf(address(this)) == amount, "CurrencyNotSettled");
    }
}

/// @dev Has no claim function or fallback, proving permissionless claimFor remains usable.
contract PassiveHolder {}

contract SITRTokenTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;
    // These are exclusively test actors, never deployment configuration.
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant DISTRIBUTOR = address(0xD157);
    uint64 private constant LAUNCH = 73;
    uint256 private constant SUPPLY = 1_000_000_000e18;

    FactoryFixture private factory;
    SITRToken private token;

    function setUp() public {
        factory = new FactoryFixture();
        token = factory.deploy(LAUNCH);
        factory.register(LAUNCH, DISTRIBUTOR);
    }

    function test_EntireSupplyMintedOnceToDeployer() public view {
        _eq(token.totalSupply(), SUPPLY);
        _eq(token.balanceOf(address(factory)), SUPPLY);
        _eq(token.balanceOf(DISTRIBUTOR), 0);
        _eq(token.balanceOf(MANAGER), 0);
        _eq(token.decimals(), 18);
        require(keccak256(bytes(token.name())) == keccak256("SI TRADER"));
        require(keccak256(bytes(token.symbol())) == keccak256("SITR"));
    }

    function test_AllocationAndSwarmClaimArriveWhole() public {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, MANAGER, SUPPLY * 9 / 10);
        _eq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10);
        _eq(token.balanceOf(MANAGER), SUPPLY * 9 / 10);
        _eq(token.balanceOf(address(factory)), 0);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, SUPPLY / 10);
        _eq(token.balanceOf(ALICE), SUPPLY / 10);
        _eq(token.balanceOf(address(token)), 0);
        _eq(token.totalSupply(), SUPPLY);
    }

    function test_OnlyBuysPayThreePercent() public {
        _holders(100 ether, 200 ether);
        uint256 managerBefore = token.balanceOf(MANAGER);
        _buy(CAROL, 100 ether);
        _eq(token.balanceOf(CAROL), 97 ether);
        _eq(managerBefore - token.balanceOf(MANAGER), 100 ether);
        _eq(token.balanceOf(address(token)), 3 ether);
        vm.prank(CAROL);
        token.transfer(BOB, 20 ether);
        vm.prank(CAROL);
        token.transfer(MANAGER, 77 ether);
        _eq(token.balanceOf(CAROL), 0);
        _eq(token.balanceOf(BOB), 220 ether);
        _eq(token.balanceOf(address(token)), 3 ether);
    }

    function test_BuyerNewBalanceDoesNotShareOwnFee() public {
        _holders(100 ether, 200 ether);
        _buy(CAROL, 100 ether);
        _eq(token.claimableDividends(CAROL), 0);
        _near(token.claimableDividends(ALICE), 1 ether, 1);
        _near(token.claimableDividends(BOB), 2 ether, 1);
    }

    function test_ReturningBuyerOnlyEarnsOnPreBuyBalance() public {
        _holders(100 ether, 200 ether);
        _buy(ALICE, 100 ether);
        _eq(token.balanceOf(ALICE), 197 ether);
        _near(token.claimableDividends(ALICE), 1 ether, 1);
        _near(token.claimableDividends(BOB), 2 ether, 1);
    }

    function test_ClaimForPaysHolderAndCanBeRepeated() public {
        _holders(100 ether, 200 ether);
        _buy(CAROL, 100 ether);
        vm.prank(CAROL);
        uint256 paid = token.claimFor(ALICE);
        _near(paid, 1 ether, 1);
        _eq(token.balanceOf(ALICE), 100 ether + paid);
        _eq(token.balanceOf(CAROL), 97 ether);
        _eq(token.claimedDividends(ALICE), paid);
        _eq(token.totalDividendsClaimed(), paid);
        _eq(token.claimFor(ALICE), 0);
        _eq(token.claimableDividends(ALICE), 0);
    }

    function test_ClaimWorksForContractWithNoClaimEntryPoint() public {
        PassiveHolder holder = new PassiveHolder();
        factory.move(token, address(holder), 100 ether);
        factory.move(token, MANAGER, SUPPLY - 100 ether);
        _buy(ALICE, 100 ether);
        uint256 paid = token.claimFor(address(holder));
        _near(paid, 3 ether, 1);
        _eq(token.balanceOf(address(holder)), 100 ether + paid);
    }

    function test_AllFourExcludedBalancesEarnNothing() public {
        factory.move(token, DISTRIBUTOR, 100 ether);
        factory.move(token, BURN, 100 ether);
        factory.move(token, address(token), 100 ether);
        factory.move(token, ALICE, 100 ether);
        factory.move(token, MANAGER, SUPPLY - 400 ether);
        _eq(token.eligibleSupply(), 100 ether);
        _buy(BOB, 100 ether);
        _near(token.claimableDividends(ALICE), 3 ether, 1);
        address[4] memory excluded = [MANAGER, address(token), BURN, DISTRIBUTOR];
        for (uint256 i; i < excluded.length; ++i) {
            require(token.isExcludedFromDividends(excluded[i]));
            _eq(token.claimableDividends(excluded[i]), 0);
            _eq(token.claimFor(excluded[i]), 0);
        }
    }

    function test_NoEligibleHoldersDoesNotCreditFirstBuyer() public {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, MANAGER, SUPPLY * 9 / 10);
        _eq(token.eligibleSupply(), 0);
        _buy(ALICE, 100 ether);
        _eq(token.unallocatedFees(), 3 ether);
        _eq(token.claimableDividends(ALICE), 0);
        _buy(BOB, 100 ether);
        _near(token.claimableDividends(ALICE), 3 ether, 1);
        _eq(token.claimableDividends(BOB), 0);
        token.claimFor(ALICE);
        require(token.balanceOf(address(token)) >= token.unallocatedFees());
    }

    function test_EarnedDividendsStayWithSellerAfterAllTokensMove() public {
        _holders(100 ether, 200 ether);
        _buy(CAROL, 100 ether);
        uint256 owed = token.claimableDividends(ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        _eq(token.claimableDividends(ALICE), owed);
        vm.prank(ALICE);
        _eq(token.claim(), owed);
        _eq(token.balanceOf(ALICE), owed);
    }

    function test_TransferCannotMoveHistoricalDividendsToReceiver() public {
        _holders(100 ether, 200 ether);
        _buy(CAROL, 100 ether);
        vm.prank(ALICE);
        token.transfer(address(this), 100 ether);
        _eq(token.claimableDividends(address(this)), 0);
        _near(token.claimableDividends(ALICE), 1 ether, 1);
    }

    function test_ClaimedTokensEarnOnlySubsequentFees() public {
        _holders(100 ether, 200 ether);
        _buy(CAROL, 100 ether);
        token.claimFor(ALICE);
        _eq(token.claimableDividends(ALICE), 0);
        uint256 eligible = token.eligibleSupply();
        uint256 held = token.balanceOf(ALICE);
        _buy(CAROL, 100 ether);
        _near(token.claimableDividends(ALICE), 3 ether * held / eligible, 1);
    }

    function test_FractionalCreditSurvivesRepeatedCheckpoints() public {
        // Three holders with one minor unit each, each 1-wei fee awards a fractional dividend.
        factory.move(token, ALICE, 1);
        factory.move(token, BOB, 1);
        factory.move(token, CAROL, 1);
        factory.move(token, MANAGER, SUPPLY - 3);
        for (uint256 i; i < 4; ++i) {
            _buy(BURN, 34);
            vm.prank(ALICE);
            token.transfer(ALICE, 0);
            token.claimFor(ALICE);
        }
        require(token.claimedDividends(ALICE) >= 1, "fractional credit lost on checkpoint");
    }

    function test_ZeroAndSelfTransfersCannotCreateDividends() public {
        _holders(100 ether, 200 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, 100 ether);
        vm.prank(MANAGER);
        token.transfer(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 0);
        _eq(token.balanceOf(ALICE), 100 ether);
        _eq(token.totalFeesCollected(), 0);
        _eq(token.claimableDividends(ALICE), 0);
    }

    function test_TransferFromTaxesSourceRatherThanCallerAndUsesGrossAllowance() public {
        _holders(100 ether, 200 ether);
        vm.prank(MANAGER);
        token.approve(CAROL, 100 ether);
        vm.prank(CAROL);
        token.transferFrom(MANAGER, CAROL, 100 ether);
        _eq(token.allowance(MANAGER, CAROL), 0);
        _eq(token.balanceOf(CAROL), 97 ether);
        _eq(token.totalFeesCollected(), 3 ether);
        vm.prank(ALICE);
        token.approve(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transferFrom(ALICE, BOB, 100 ether);
        _eq(token.balanceOf(BOB), 300 ether);
        _eq(token.totalFeesCollected(), 3 ether);
    }

    function test_InfiniteApprovalIsPreserved() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 100 ether);
        _eq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function test_InvalidTransfersRevertWithoutChangingAccounting() public {
        _holders(100 ether, 200 ether);
        vm.prank(ALICE);
        vm.expectRevert(SITRToken.InsufficientBalance.selector);
        token.transfer(BOB, 101 ether);
        vm.prank(ALICE);
        vm.expectRevert(SITRToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.prank(BOB);
        vm.expectRevert(SITRToken.InsufficientAllowance.selector);
        token.transferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        token.approve(BOB, 200 ether);
        vm.prank(BOB);
        vm.expectRevert(SITRToken.InsufficientBalance.selector);
        token.transferFrom(ALICE, BOB, 101 ether);
        _eq(token.allowance(ALICE, BOB), 200 ether);
        _eq(token.totalFeesCollected(), 0);
        _eq(token.balanceOf(ALICE), 100 ether);
    }

    function test_DistributorMayBeRegisteredAfterDeploymentAndCannotBeChanged() public {
        FactoryFixture lateFactory = new FactoryFixture();
        SITRToken late = lateFactory.deploy(LAUNCH);
        lateFactory.move(late, MANAGER, SUPPLY / 2);
        vm.prank(MANAGER);
        vm.expectRevert(SITRToken.DistributorUnavailable.selector);
        late.transfer(ALICE, 100 ether);
        lateFactory.register(LAUNCH, DISTRIBUTOR);
        lateFactory.move(late, DISTRIBUTOR, SUPPLY / 10);
        lateFactory.register(LAUNCH, CAROL);
        require(late.swarmDistributor() == DISTRIBUTOR, "resolved distributor changed");
        vm.prank(MANAGER);
        late.transfer(ALICE, 100 ether);
        _eq(late.claimableDividends(DISTRIBUTOR), 0);
        _eq(late.claimableDividends(ALICE), 0);
    }

    function test_SeedBuyAndSellSettleExactManagerDeltas() public {
        vm.etch(MANAGER, address(new SettlementFixture()).code);
        SettlementFixture manager = SettlementFixture(MANAGER);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        vm.startPrank(address(factory));
        token.approve(MANAGER, SUPPLY * 9 / 10);
        manager.settleInput(token, SUPPLY * 9 / 10);
        vm.stopPrank();
        manager.takeOutput(token, ALICE, 100 ether);
        _eq(token.balanceOf(ALICE), 97 ether);
        vm.startPrank(ALICE);
        token.approve(MANAGER, 97 ether);
        manager.settleInput(token, 97 ether);
        vm.stopPrank();
        _eq(token.balanceOf(ALICE), 0);
        _eq(token.balanceOf(MANAGER), SUPPLY * 9 / 10 - 3 ether);
    }

    function test_NoMintAdminOrPrivilegedBalanceMovement() public {
        factory.move(token, ALICE, 100 ether);
        string[13] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, 100 ether));
            require(!ok, "unexpected privileged entry point");
        }
        _eq(token.balanceOf(ALICE), 100 ether);
        _eq(token.totalSupply(), SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        _eq(token.balanceOf(BOB), 100 ether);
    }

    function test_RuntimeHasNoForbiddenInstructions() public view {
        bytes memory code = address(token).code;
        require(code.length <= 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else require(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden instruction");
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BuyConservationAndPreBuyProportions(uint96 a, uint96 b, uint96 buy) public {
        uint256 alice = uint256(a) % (SUPPLY / 4) + 1;
        uint256 bob = uint256(b) % (SUPPLY / 4) + 1;
        _holders(alice, bob);
        uint256 amount = uint256(buy) % token.balanceOf(MANAGER);
        uint256 fee = amount * 3 / 100;
        _buy(CAROL, amount);
        _eq(token.balanceOf(CAROL), amount - fee);
        _eq(token.balanceOf(address(token)), fee);
        _eq(token.claimableDividends(CAROL), 0);
        _near(token.claimableDividends(ALICE), fee * alice / (alice + bob), 1);
        _near(token.claimableDividends(BOB), fee * bob / (alice + bob), 1);
        token.claimFor(ALICE);
        token.claimFor(BOB);
        _eq(
            token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL) + token.balanceOf(MANAGER)
                + token.balanceOf(address(token)),
            SUPPLY
        );
        require(token.totalDividendsClaimed() <= fee);
    }

    /// @dev Stateful fuzzing across buys, sells, transfers, excluded deposits and third-party claims.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SequencesPreserveSupplyAndDividendSolvency(bytes32 seed) public {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, ALICE, 100 ether);
        factory.move(token, BOB, 200 ether);
        factory.move(token, MANAGER, SUPPLY * 9 / 10 - 300 ether);
        address[7] memory actors = [ALICE, BOB, CAROL, DISTRIBUTOR, MANAGER, BURN, address(token)];
        uint256 fees;
        for (uint256 step; step < 64; ++step) {
            seed = keccak256(abi.encode(seed, step));
            uint256 r = uint256(seed);
            address from = actors[r % 5];
            address to = actors[(r >> 8) % actors.length];
            if ((r >> 16) % 3 == 0) {
                uint256 beforeTo = token.balanceOf(to);
                uint256 beforeCaller = token.balanceOf(address(this));
                uint256 paid = token.claimFor(to);
                _eq(token.balanceOf(to), beforeTo + paid);
                _eq(token.balanceOf(address(this)), beforeCaller);
            } else {
                uint256 amount = (r >> 32) % (token.balanceOf(from) + 1);
                if (from == MANAGER && to != MANAGER) fees += amount * 3 / 100;
                vm.prank(from);
                token.transfer(to, amount);
            }
            uint256 sum;
            uint256 liabilities;
            for (uint256 i; i < actors.length; ++i) {
                sum += token.balanceOf(actors[i]);
                liabilities += token.claimableDividends(actors[i]);
            }
            _eq(sum, SUPPLY);
            _eq(token.totalSupply(), SUPPLY);
            _eq(token.totalFeesCollected(), fees);
            require(liabilities <= token.balanceOf(address(token)), "dividends insolvent");
            require(token.totalDividendsClaimed() + token.unallocatedFees() <= fees, "fees overpaid");
            _eq(token.claimableDividends(MANAGER), 0);
            _eq(token.claimableDividends(DISTRIBUTOR), 0);
            _eq(token.claimableDividends(BURN), 0);
            _eq(token.claimableDividends(address(token)), 0);
            _eq(token.eligibleSupply(), token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL));
        }
    }

    function _holders(uint256 alice, uint256 bob) private {
        factory.move(token, ALICE, alice);
        factory.move(token, BOB, bob);
        factory.move(token, MANAGER, SUPPLY - alice - bob);
    }

    function _buy(address to, uint256 amount) private {
        vm.prank(MANAGER);
        token.transfer(to, amount);
    }

    function _eq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "not equal");
    }

    function _near(uint256 actual, uint256 expected, uint256 tolerance) private pure {
        require(actual <= expected + tolerance && expected <= actual + tolerance, "outside tolerance");
    }
}
