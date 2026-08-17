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

// TODO(glowyusds): RENAME PENDING. Fork of src/shinyusds/, which is itself a fork of
// src/srusds/. Every srUSDS identifier below -- contract SrUsds, srusds, SrUsdsLike,
// "Senior Risk USDS", "srUSDS" -- is intentionally UNCHANGED so the chain of diffs stays
// readable. Rename the whole tree to glowyUSDS once the functional diff has been reviewed.
//
// This is src/shinyusds/ plus a continuously-accruing rate, so diff against that first:
//   diff src/shinyusds/ShinyUsds.sol src/glowyusds/GlowyUsds.sol
//
// Inherited from shinyusds (differences vs src/srusds/SrUsds.sol):
//   1. settle() moves no assets; it only marks chi. Backing enters by plain transfer to this
//      contract and leaves via take(), so a loss can be recognised while the backing is
//      deployed with the asset manager and therefore cannot be transferred out.
//   2. take(uint256) added, behind a new `buds`/`toll` role.
//   3. chi derived directly from the new backing, so a total loss is recoverable.
//   4. deposit() guards chi > 0.
//
// New in glowyusds -- a fixed, administered APY in the style of sUSDS/sDAI:
//   5. `rate` (per-second [ray]) accrues into chi continuously, with `rho` finally being read
//      rather than merely written. nowChi() previews it, drip() folds it in. Every chi read
//      site now goes through one of the two.
//   6. `rate` is bounded by governance-set `minRate`/`maxRate`, mirroring Spark Vault V2's
//      setVsrBounds so the day-to-day setter cannot promise an arbitrary yield. All three
//      default to RAY (0%) at initialize; nothing accrues until governance opens the band.
//      The File event, previously declared and unused, is now emitted by file().
//
// CONSEQUENCE: settleAmt changes meaning. It is no longer the whole return -- it is the
// TRUE-UP between the promised rate and what the strategy actually delivered. A fixed rate is
// a promise, and whoever is behind it absorbs the gap. With external depositors and no
// backstop an over-promised rate is a solvency hole that stays invisible until people try to
// exit, because chi keeps accruing value the vault cannot honour. See NOTES.md Q1.

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
    mapping (address => uint256) public buds;  // Asset manager (take) permission
    // ERC20
    uint256                                           public totalSupply;
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => uint256)                      public nonces;
    // Savings yield
    uint192 public chi;      // The Rate Accumulator             [ray]
    uint64  public rho;      // Time of last drip                [unix epoch time]
    uint256 public rate;     // Per-second accrual rate          [ray], RAY == 0% APY
    uint256 public minRate;  // Lower bound governance allows    [ray]
    uint256 public maxRate;  // Upper bound governance allows    [ray]

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
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Settle(int256 assets, uint256 oldChi, uint256 newChi);
    event Take(address indexed usr, uint256 assets);
    // ERC20
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    // ERC4626
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    // --- Modifiers ---

    modifier auth {
        require(wards[msg.sender] == 1, "SrUsds/not-authorized");
        _;
    }

    /// @dev Narrow role for the asset manager, deliberately separate from `auth`. A ward can
    ///      settle(), deposit() and redeem(); the asset manager must be able to do none of
    ///      those, only move deployed backing. Mirrors Spark Vault V2's TAKER_ROLE, which is
    ///      what lets the PAU's ALMProxy hold this permission safely.
    modifier toll {
        require(buds[msg.sender] == 1, "SrUsds/not-permitted");
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

        chi     = uint192(RAY);
        rho     = uint64(block.timestamp);
        rate    = RAY;  // 0% until governance opens the band and files a rate
        minRate = RAY;
        maxRate = RAY;
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

    function _rpow(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxround := add(xx, half)
                    if lt(xxround, xx) { revert(0,0) }
                    x := div(xxround, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxround := add(zx, half)
                        if lt(zxround, zx) { revert(0,0) }
                        z := div(zxround, base)
                    }
                }
            }
        }
    }

    // --- Rate Accrual ---

    /// @notice chi as of now, including accrual since the last drip
    function nowChi() public view returns (uint256 nChi) {
        uint256 rate_ = rate;
        nChi = (rate_ == RAY || block.timestamp == rho)
             ? chi
             : _rpow(rate_, block.timestamp - rho, RAY) * chi / RAY;
    }

    /// @notice Fold accrued interest into chi
    /// @dev Permissionless. Must be called before any read or write of chi that matters,
    ///      and before changing `rate`, so that the old rate applies to the elapsed period.
    function drip() public returns (uint256 nChi) {
        nChi = nowChi();
        chi  = _toUint192(nChi);
        rho  = uint64(block.timestamp);
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

    function kiss(address usr) external auth {
        buds[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external auth {
        buds[usr] = 0;
        emit Diss(usr);
    }

    /// @dev `rate` is the promised accrual. Bounds are governance-set, mirroring Spark Vault
    ///      V2's setVsrBounds, so the day-to-day setter cannot promise an arbitrary yield.
    ///      Both default to RAY (0%) at initialize, so nothing accrues until governance opens
    ///      the band.
    function file(bytes32 what, uint256 data) external auth {
        if (what == "rate") {
            require(data >= minRate && data <= maxRate, "SrUsds/rate-out-of-bounds");
            drip();  // old rate applies to the elapsed period
            rate = data;
        } else if (what == "minRate") {
            require(data <= maxRate, "SrUsds/minRate-above-maxRate");
            require(data >= RAY,     "SrUsds/minRate-below-ray");
            minRate = data;
        } else if (what == "maxRate") {
            require(data >= minRate, "SrUsds/maxRate-below-minRate");
            maxRate = data;
        } else revert("SrUsds/file-unrecognized-param");
        emit File(what, data);
    }

    /// @dev Moves no assets -- marks chi only. See the TODO block at the top of the file.
    function settle(int256 assets) external auth returns (uint256 newChi) {
        uint256 supply = totalSupply;
        require(supply > 0, "SrUsds/no-supply");

        // Fold in accrual first, so settleAmt is a true-up against the promised rate rather
        // than the whole return.
        uint256 oldChi = drip();
        uint256 totalAssets_ = supply * oldChi / RAY;
        uint256 newTotalAssets;
        if (assets > 0) {
            newTotalAssets = totalAssets_ + uint256(assets);
        } else {
            uint256 assets_ = _min(uint256(-assets), totalAssets_);
            newTotalAssets = totalAssets_ - assets_;
        }
        // Derived from the new backing directly rather than as a ratio against the old, so
        // that a total loss (chi == 0) can still be recovered by a later positive settle.
        newChi = chi = _toUint192(newTotalAssets * RAY / supply);
        rho = uint64(block.timestamp);
        emit Settle(assets, oldChi, newChi);
    }

    /// @notice Remove backing for deployment by the asset manager
    /// @dev `take(uint256)` sending to msg.sender, so the Diamond PAU can drive it through its
    ///      existing SparkVaultFacet (ISparkVaultLike.take) with no new facet code. Sizing is
    ///      bounded by the PAU's LIMIT_SPARK_VAULT_TAKE rate limit, hence no cap here.
    ///
    ///      Does not change chi: the backing remains a claim of the holders, it is simply
    ///      custodied elsewhere. This contract is expected to hold less than totalAssets()
    ///      whenever capital is deployed, so there is deliberately no solvency check.
    ///
    ///      No matching `give`: backing is returned by plain ERC20 transfer to this contract,
    ///      as Spark Vault V2 is funded via the PAU's TransferAssetFacet. Since totalAssets()
    ///      derives from chi rather than the token balance, an inbound transfer needs no
    ///      bookkeeping. Use settle() to recognise the gain or loss.
    function take(uint256 assets) external toll {
        susds.transfer(msg.sender, assets);
        emit Take(msg.sender, assets);
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

    function convertToShares(uint256 assets) external view returns (uint256) {
        uint256 chi_ = nowChi();
        return chi_ > 0 ? assets * RAY / chi_ : 0;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * nowChi() / RAY;
    }

    function deposit(uint256 assets, address receiver) external auth returns (uint256 shares) {
        uint256 chi_ = drip();
        require(chi_ > 0, "SrUsds/chi-zero");
        shares = assets * RAY / chi_;
        _mint(assets, shares, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) external auth returns (uint256 assets) {
        assets = shares * drip() / RAY;
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
