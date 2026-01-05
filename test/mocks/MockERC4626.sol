// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

/// @title MockERC4626
/// @notice A simple ERC4626 vault mock for testing LCTS queues
contract MockERC4626 {
    string public constant name = "Mock Vault";
    string public constant symbol = "mVAULT";
    uint8 public constant decimals = 18;

    address public immutable asset;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Configurable exchange rate (assets per share, in WAD)
    uint256 public rate = 1e18; // 1:1 by default

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    constructor(address asset_) {
        asset = asset_;
    }

    // --- ERC20 ---

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockERC4626/insufficient-balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "MockERC4626/insufficient-balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "MockERC4626/insufficient-allowance");
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // --- ERC4626 ---

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(shares > 0, "MockERC4626/zero-shares");

        MockERC20(asset).transferFrom(msg.sender, address(this), assets);

        totalSupply += shares;
        balanceOf[receiver] += shares;

        emit Deposit(msg.sender, receiver, assets, shares);
        emit Transfer(address(0), receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(balanceOf[owner] >= shares, "MockERC4626/insufficient-balance");
        if (owner != msg.sender && allowance[owner][msg.sender] != type(uint256).max) {
            require(allowance[owner][msg.sender] >= shares, "MockERC4626/insufficient-allowance");
            allowance[owner][msg.sender] -= shares;
        }

        assets = convertToAssets(shares);

        balanceOf[owner] -= shares;
        totalSupply -= shares;

        MockERC20(asset).transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        emit Transfer(owner, address(0), shares);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * 1e18 / rate;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * rate / 1e18;
    }

    // --- Test Helpers ---

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function mint(address to, uint256 shares) external {
        totalSupply += shares;
        balanceOf[to] += shares;
        emit Transfer(address(0), to, shares);
    }
}

/// @title MockERC20
/// @notice A simple ERC20 mock for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockERC20/insufficient-balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "MockERC20/insufficient-balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "MockERC20/insufficient-allowance");
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) external {
        require(balanceOf[from] >= value, "MockERC20/insufficient-balance");
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }
}
