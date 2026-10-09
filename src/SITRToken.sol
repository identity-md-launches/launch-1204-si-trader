// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ILaunchDistributorRegistry {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @notice Fixed-supply SI TRADER with dividends funded only by PoolManager outflows.
/// @dev The factory registers the launch's distributor after creating the token. The first
/// nonzero registry result is pinned permanently; no account can change token parameters.
contract SITRToken {
    string public constant name = "SI TRADER";
    string public constant symbol = "SITR";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000e18;
    uint256 public constant BUY_FEE_BPS = 300;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAGNITUDE = 1 << 128;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    uint64 public immutable launchNumber;
    address private _distributor;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) private _checkpoint;
    mapping(address => uint256) private _accruedScaled;
    mapping(address => uint256) public claimedDividends;

    uint256 public dividendPerShare;
    uint256 public totalFeesCollected;
    uint256 public totalDividendsClaimed;
    /// @notice Fees paid when no eligible balance exists; never awarded to the incoming buyer.
    uint256 public unallocatedFees;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DistributorResolved(address indexed distributor);
    event DividendsDistributed(uint256 fee, uint256 eligibleBalance);
    event DividendClaimed(address indexed holder, uint256 amount);

    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error DistributorUnavailable();
    error InvalidDistributor();

    /// @param launchNumber_ The factory's actual launch identifier, supplied as $launchNumber.
    constructor(uint64 launchNumber_) {
        factory = msg.sender;
        launchNumber = launchNumber_;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) {
            if (permitted < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = permitted - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function swarmDistributor() public view returns (address) {
        if (_distributor != address(0)) return _distributor;
        // A missing registration is normal while the factory is constructing the launch.
        // Validate the return data explicitly: a high-level try/catch does not catch
        // decoding failures from a successful call that returns malformed data.
        (bool success, bytes memory result) =
            factory.staticcall(abi.encodeCall(ILaunchDistributorRegistry.distributorOf, (launchNumber)));
        if (!success || result.length < 32) return address(0);
        uint256 encoded = abi.decode(result, (uint256));
        if (encoded > type(uint160).max) return address(0);
        // The range check above ensures the cast cannot truncate the registry value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(encoded));
    }

    function isExcludedFromDividends(address account) public view returns (bool) {
        return _isExcluded(account, swarmDistributor());
    }

    function eligibleSupply() public view returns (uint256) {
        return _eligibleSupply(swarmDistributor());
    }

    function claimableDividends(address holder) public view returns (uint256) {
        if (_isExcluded(holder, swarmDistributor())) return 0;
        return (_accruedScaled[holder] + balanceOf[holder] * (dividendPerShare - _checkpoint[holder])) / MAGNITUDE;
    }

    function claim() external returns (uint256) {
        return _claimFor(msg.sender);
    }

    /// @notice Anyone may trigger a payment, but only the named holder receives it.
    function claimFor(address holder) external returns (uint256) {
        return _claimFor(holder);
    }

    function _claimFor(address holder) private returns (uint256 amount) {
        address distributor = _resolveDistributor();
        if (_isExcluded(holder, distributor)) return 0;
        _accrue(holder, distributor);
        amount = _accruedScaled[holder] / MAGNITUDE;
        if (amount == 0) return 0;
        // Keep sub-unit credit so frequent claims/checkpoints do not erase fractions.
        _accruedScaled[holder] %= MAGNITUDE;
        claimedDividends[holder] += amount;
        totalDividendsClaimed += amount;
        // All effects precede payment. This is an internal ERC-20 move with no callbacks.
        balanceOf[address(this)] -= amount;
        balanceOf[holder] += amount;
        emit Transfer(address(this), holder, amount);
        emit DividendClaimed(holder, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        address distributor = _resolveDistributor();
        _accrue(from, distributor);
        _accrue(to, distributor);

        uint256 fee = 0;
        // Self-transfers settle no currency and transfers TO the manager are always exact.
        if (from == POOL_MANAGER && to != POOL_MANAGER) {
            fee = amount * BUY_FEE_BPS / BPS;
            if (fee != 0) {
                if (distributor == address(0)) revert DistributorUnavailable();
                uint256 eligible = _eligibleSupply(distributor);
                totalFeesCollected += fee;
                if (eligible == 0) {
                    unallocatedFees += fee;
                } else {
                    // The fee is intentionally rounded to token minor units before allocation.
                    // forge-lint: disable-next-line(divide-before-multiply)
                    dividendPerShare += fee * MAGNITUDE / eligible;
                }
                emit DividendsDistributed(fee, eligible);
                // The buyer earns on its OLD balance only. Settle the new index before
                // crediting any of this buy's net tokens, including a first-time buyer.
                _accrue(to, distributor);
            }
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        emit Transfer(from, to, amount - fee);
        if (fee != 0) {
            balanceOf[address(this)] += fee;
            emit Transfer(from, address(this), fee);
        }
    }

    function _accrue(address holder, address distributor) private {
        if (_isExcluded(holder, distributor)) return;
        _accruedScaled[holder] += balanceOf[holder] * (dividendPerShare - _checkpoint[holder]);
        _checkpoint[holder] = dividendPerShare;
    }

    function _resolveDistributor() private returns (address distributor) {
        distributor = swarmDistributor();
        if (_distributor == address(0) && distributor != address(0)) {
            if (
                distributor == factory || distributor == POOL_MANAGER || distributor == address(this)
                    || distributor == BURN_ADDRESS
            ) revert InvalidDistributor();
            _distributor = distributor;
            emit DistributorResolved(distributor);
        }
    }

    function _isExcluded(address holder, address distributor) private view returns (bool) {
        return holder == address(0) || holder == POOL_MANAGER || holder == address(this) || holder == BURN_ADDRESS
            || holder == distributor;
    }

    function _eligibleSupply(address distributor) private view returns (uint256 eligible) {
        eligible = totalSupply - balanceOf[POOL_MANAGER] - balanceOf[address(this)] - balanceOf[BURN_ADDRESS];
        if (
            distributor != address(0) && distributor != POOL_MANAGER && distributor != address(this)
                && distributor != BURN_ADDRESS
        ) eligible -= balanceOf[distributor];
    }
}
