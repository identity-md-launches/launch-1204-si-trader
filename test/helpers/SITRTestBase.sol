// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../vendor/forge-std/Test.sol";
import {SITRToken} from "../../src/SITRToken.sol";
import {FactoryFixture} from "../SITRToken.t.sol";

abstract contract SITRTestBase is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint64 internal constant LAUNCH = 73;
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    // Test actors only; these values are never passed to a deployment manifest.
    address internal alice = makeAddr("sitr alice");
    address internal bob = makeAddr("sitr bob");
    address internal carol = makeAddr("sitr carol");
    address internal distributor = makeAddr("sitr distributor");
    FactoryFixture internal factory;
    SITRToken internal token;

    function setUp() public virtual {
        factory = new FactoryFixture();
        token = factory.deploy(LAUNCH);
        factory.register(LAUNCH, distributor);
    }

    function _holders(uint256 a, uint256 b) internal {
        factory.move(token, alice, a);
        factory.move(token, bob, b);
        factory.move(token, MANAGER, SUPPLY - a - b);
    }

    function _buy(address recipient, uint256 amount) internal {
        vm.prank(MANAGER);
        assertTrue(token.transfer(recipient, amount));
    }

    function _accountingHash() internal view returns (bytes32) {
        bytes32 digest = keccak256(
            abi.encode(
                token.totalSupply(),
                token.totalFeesCollected(),
                token.totalDividendsClaimed(),
                token.unallocatedFees(),
                token.dividendPerShare(),
                token.eligibleSupply(),
                token.swarmDistributor(),
                token.allowance(alice, bob),
                token.allowance(MANAGER, carol)
            )
        );
        address[8] memory accounts = [alice, bob, carol, distributor, MANAGER, BURN, address(token), address(factory)];
        for (uint256 i; i < accounts.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    token.balanceOf(accounts[i]),
                    token.claimableDividends(accounts[i]),
                    token.claimedDividends(accounts[i])
                )
            );
        }
        return digest;
    }
}
