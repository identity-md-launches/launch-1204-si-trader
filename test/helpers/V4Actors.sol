// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SITRToken} from "../../src/SITRToken.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "../vendor/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";

/// @dev Only the paired currency is mocked. PoolManager pricing, liquidity, fee growth,
/// transient currency deltas, and unlock settlement are the upstream implementation.
contract V4PairToken {
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Test-only factory/trader callback. The factory owns the constructor-minted supply and
/// pays its seed directly; independent trader instances have no special SITR privileges.
contract V4Actor is IUnlockCallback {
    IPoolManager public immutable manager;
    mapping(uint64 => address) public distributorOf;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deploy(uint64 launch) external returns (SITRToken) {
        return new SITRToken(launch);
    }

    function register(uint64 launch, address distributor) external {
        distributorOf[launch] = distributor;
    }

    function move(SITRToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "move failed");
    }

    function seed(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity) external returns (BalanceDelta) {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0));
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params))), (BalanceDelta));
    }

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amount,
        address recipient,
        bool underpay,
        bool claimOutput
    ) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), key, abi.encode(zeroForOne, amount, recipient, underpay, claimOutput))),
            (BalanceDelta)
        );
    }

    function redeem(PoolKey memory key, Currency currency, uint256 amount, address recipient) external {
        manager.unlock(abi.encode(uint8(2), key, abi.encode(currency, amount, recipient)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "unexpected callback");
        (uint8 action, PoolKey memory key, bytes memory payload) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            IPoolManager.ModifyLiquidityParams memory params = abi.decode(payload, (IPoolManager.ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
            _settle(key.currency0, delta.amount0(), address(this), false, false);
            _settle(key.currency1, delta.amount1(), address(this), false, false);
        } else if (action == 1) {
            (bool direction, int256 amount, address recipient, bool underpay, bool claimOutput) =
                abi.decode(payload, (bool, int256, address, bool, bool));
            uint160 limit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = manager.swap(key, IPoolManager.SwapParams(direction, amount, limit), "");
            _settle(key.currency0, delta.amount0(), recipient, underpay, claimOutput);
            _settle(key.currency1, delta.amount1(), recipient, underpay, claimOutput);
        } else {
            (Currency currency, uint256 amount, address recipient) = abi.decode(payload, (Currency, uint256, address));
            manager.burn(address(this), currency.toId(), amount);
            manager.take(currency, recipient, amount);
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address recipient, bool underpay, bool claimOutput) private {
        if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            manager.sync(currency);
            require(IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), debt - (underpay ? 1 : 0)));
            manager.settle();
        } else if (delta > 0) {
            uint256 credit = uint256(int256(delta));
            if (claimOutput) manager.mint(address(this), currency.toId(), credit);
            else manager.take(currency, recipient, credit);
        }
    }
}
