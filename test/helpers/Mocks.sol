// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        totalSupply -= amount;
        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice The loss-history and pull-balance surface of HamsterHour v2, settable by tests.
contract MockGame {
    address public immutable IMD;
    uint256 public nextFinalizeWindow;
    uint256 public cumulativeLoss;
    address public stakingRecipient;
    uint256 public pendingStakingFees;
    mapping(uint256 => uint256) public totalEligibleLoss;
    mapping(uint256 => uint256) public cumulativeLossBefore;
    mapping(uint256 => uint256) public cumulativeLossAfter;
    mapping(uint256 => mapping(address => uint256)) public lossOf;
    mapping(address => uint256) public balances;

    error NothingToClaim();

    constructor(address imd) {
        IMD = imd;
    }

    /// @dev Finalizes the next window with the given per-account losses. `total` may exceed the sum
    /// (hedging) but never be below it, as in the real game.
    function finalizeWindow(address[] memory accounts, uint256[] memory losses, uint256 total) external {
        uint256 k = nextFinalizeWindow;
        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            lossOf[k][accounts[i]] += losses[i];
            sum += losses[i];
        }
        require(total >= sum, "total below sum");
        totalEligibleLoss[k] = total;
        cumulativeLossBefore[k] = cumulativeLoss;
        cumulativeLoss += total;
        cumulativeLossAfter[k] = cumulativeLoss;
        nextFinalizeWindow = k + 1;
    }

    function finalizeEmpty() external {
        uint256 k = nextFinalizeWindow;
        cumulativeLossBefore[k] = cumulativeLoss;
        cumulativeLossAfter[k] = cumulativeLoss;
        nextFinalizeWindow = k + 1;
    }

    function creditStakers(uint256 amount) external {
        if (stakingRecipient == address(0)) pendingStakingFees += amount;
        else balances[stakingRecipient] += amount;
    }

    function setStakingRecipient(address r) external {
        stakingRecipient = r;
        balances[r] += pendingStakingFees;
        pendingStakingFees = 0;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balances[msg.sender] = 0;
        require(MockERC20(IMD).transfer(msg.sender, amount));
    }
}

contract MockERC721 {
    mapping(uint256 => address) internal _owners;
    bool public erc721 = true;

    function setSupports(bool v) external {
        erc721 = v;
    }

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function transfer(uint256 id, address to) external {
        _owners[id] = to;
    }

    function burn(uint256 id) external {
        delete _owners[id];
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = _owners[id];
        require(o != address(0), "no token");
        return o;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        return erc721 && id == 0x80ac58cd;
    }
}
