// SPDX-License-Identifier: AGPL-3.0-or-later

/// SrUsds.sol

// Copyright (C) 2017, 2018, 2019 dbrock, rain, mrchico
// Copyright (C) 2021 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IERC1271 {
    function isValidSignature(
        bytes32,
        bytes memory
    ) external view returns (bytes4);
}

interface SUsdsLike {
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

contract SrUsds is UUPSUpgradeable {

    // --- Storage Variables ---

    // Admin
    mapping (address => uint256) public wards;
    // ERC20
    uint256                                           public totalSupply;
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => uint256)                      public nonces;
    // Savings yield
    uint192 public chi;   // The Rate Accumulator [ray]
    uint64  public rho;   // Time of last settle  [unix epoch time]

    // --- Constants ---

    // ERC20
    string  public constant name     = "Senior Risk USDS";
    string  public constant symbol   = "srUSDS";
    string  public constant version  = "1";
    uint8   public constant decimals = 18;
    // Math
    uint256 private constant RAY = 10 ** 27;
    // EIP712
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // --- Immutables ---

    SUsdsLike public immutable susds;

    // --- Events ---

    // Admin
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Settle(int256 assets, uint256 oldChi, uint256 newChi);
    // ERC20
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    // ERC4626
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    // Referral
    event Referral(uint16 indexed referral, address indexed owner, uint256 assets, uint256 shares);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "SrUsds/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address susds_) {
        _disableInitializers(); // Avoid initializing in the context of the implementation

        susds = SUsdsLike(susds_);
    }

    // --- Upgradability ---

    function initialize() initializer external {
        __UUPSUpgradeable_init();

        chi = uint192(RAY);
        rho = uint64(block.timestamp);
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override auth {}

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    // --- Internals ---

    // EIP712

    function _calculateDomainSeparator(uint256 chainId) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                address(this)
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _calculateDomainSeparator(block.chainid);
    }

    // Math

    function _toUint192(uint256 a) internal pure returns (uint192 b) {
        require(a <= type(uint192).max);
        b = uint192(a);
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    // --- Admin external functions ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function settle(int256 assets) external auth returns (uint256 newChi) {
        uint256 oldChi = chi;
        uint256 totalAssets_ = totalSupply * oldChi / RAY;
        uint256 newTotalAssets;
        if (assets > 0) {
            susds.transferFrom(msg.sender, address(this), uint256(assets));
            newTotalAssets = totalAssets_ + uint256(assets);
        } else {
            uint256 assets_ = _min(uint256(-assets), totalAssets_);
            susds.transfer(msg.sender, assets_);
            newTotalAssets = totalAssets_ - assets_;
        }
        newChi = chi = totalAssets_ > 0
                               ? _toUint192(oldChi * newTotalAssets / totalAssets_)
                               : 0;
        rho = uint64(block.timestamp);
        emit Settle(assets, oldChi, newChi);
    }

    // --- ERC20 Mutations ---

    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SrUsds/invalid-address");
        uint256 balance = balanceOf[msg.sender];
        require(balance >= value, "SrUsds/insufficient-balance");

        unchecked {
            balanceOf[msg.sender] = balance - value;
            balanceOf[to] += value; // note: we don't need an overflow check here b/c sum of all balances == totalSupply
        }

        emit Transfer(msg.sender, to, value);

        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SrUsds/invalid-address");
        uint256 balance = balanceOf[from];
        require(balance >= value, "SrUsds/insufficient-balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "SrUsds/insufficient-allowance");

                unchecked {
                    allowance[from][msg.sender] = allowed - value;
                }
            }
        }

        unchecked {
            balanceOf[from] = balance - value;
            balanceOf[to] += value; // note: we don't need an overflow check here b/c sum of all balances == totalSupply
        }

        emit Transfer(from, to, value);

        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;

        emit Approval(msg.sender, spender, value);

        return true;
    }

    // --- Mint/Burn Internal ---

    function _mint(uint256 assets, uint256 shares, address receiver) internal {
        require(receiver != address(0) && receiver != address(this), "SrUsds/invalid-address");

        susds.transferFrom(msg.sender, address(this), assets);

        unchecked {
            balanceOf[receiver] = balanceOf[receiver] + shares; // note: we don't need an overflow check here b/c balanceOf[receiver] <= totalSupply
        }
        totalSupply = totalSupply + shares;

        emit Deposit(msg.sender, receiver, assets, shares);
        emit Transfer(address(0), receiver, shares);
    }

    function _burn(uint256 assets, uint256 shares, address receiver, address owner) internal {
        uint256 balance = balanceOf[owner];
        require(balance >= shares, "SrUsds/insufficient-balance");

        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "SrUsds/insufficient-allowance");

                unchecked {
                    allowance[owner][msg.sender] = allowed - shares;
                }
            }
        }

        unchecked {
            balanceOf[owner] = balance - shares; // note: we don't need overflow checks b/c require(balance >= shares) and balance <= totalSupply
            totalSupply      = totalSupply - shares;
        }

        susds.transfer(receiver, assets);

        emit Transfer(owner, address(0), shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // --- ERC-4626 ---

    function asset() external view returns (address) {
        return address(susds);
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 chi_ = chi;
        return chi_ > 0 ? assets * RAY / chi_ : 0;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * chi / RAY;
    }

    function maxDeposit(address) external view returns (uint256) {
        uint256 chi_ = chi;
        return chi_ == 0 ? 0 : type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function deposit(uint256 assets, address receiver) external auth returns (uint256 shares) {
        shares = assets * RAY / chi;
        _mint(assets, shares, receiver);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return chi > 0 ? balanceOf[owner] : 0;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external auth returns (uint256 assets) {
        assets = shares * chi / RAY;
        require(assets > 0, "SrUsds/assets-zero");
        _burn(assets, shares, receiver, owner);
    }

    // --- Approve by signature ---

    function _isValidSignature(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal view returns (bool valid) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            if (signer == ecrecover(digest, v, r, s)) {
                return true;
            }
        }

        if (signer.code.length > 0) {
            (bool success, bytes memory result) = signer.staticcall(
                abi.encodeCall(IERC1271.isValidSignature, (digest, signature))
            );
            valid = (success &&
                result.length == 32 &&
                abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector);
        }
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) public {
        require(block.timestamp <= deadline, "SrUsds/permit-expired");
        require(owner != address(0), "SrUsds/invalid-owner");

        uint256 nonce;
        unchecked { nonce = nonces[owner]++; }

        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                _calculateDomainSeparator(block.chainid),
                keccak256(abi.encode(
                    PERMIT_TYPEHASH,
                    owner,
                    spender,
                    value,
                    nonce,
                    deadline
                ))
            ));

        require(_isValidSignature(owner, digest, signature), "SrUsds/invalid-permit");

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }
}
