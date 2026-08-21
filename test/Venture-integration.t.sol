// SPDX-License-Identifier: AGPL-3.0-or-later

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

import "token-tests/TokenFuzzChecks.sol";
import "dss-interfaces/Interfaces.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Venture, UUPSUpgradeable, Initializable, ERC1967Utils } from "src/Venture.sol";
import { VentureHandler } from "src/VentureHandler.sol";

import { VentureInstance } from "deploy/VentureInstance.sol";
import { VentureDeploy } from "deploy/VentureDeploy.sol";
import { VentureInit, VentureConfig } from "deploy/VentureInit.sol";

interface SUsdsLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

interface UsdsLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

contract Venture2 is UUPSUpgradeable {
    // Admin
    mapping (address => uint256) public wards;
    // ERC20
    uint256                                           public totalSupply;
    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => uint256)                      public nonces;
    // Savings yield
    uint192 public chi;
    uint64  public rho;
    uint256 public srr;

    string  public constant version  = "2";

    event UpgradedTo(string version);

    modifier auth {
        require(wards[msg.sender] == 1, "Venture/not-authorized");
        _;
    }

    constructor() {
        _disableInitializers(); // Avoid initializing in the context of the implementation
    }

    function reinitialize() reinitializer(2) external {
        emit UpgradedTo(version);
    }

    function _authorizeUpgrade(address newImplementation) internal override auth {}

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}

contract VentureIntegrationTest is TokenFuzzChecks {

    using GodMode for *;

    ChainlogAbstract LOG;

    DssInstance dss;
    address pauseProxy;
    SUsdsLike susds;
    UsdsLike usds;

    Venture token;
    VentureHandler handler;
    bool validate;

    event Settle(int256 assets, uint256 oldChi, uint256 newChi);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event UpgradedTo(string version);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        validate = vm.envOr("VALIDATE", false);

        LOG = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
        dss = MCD.loadFromChainlog(LOG);

        pauseProxy = LOG.getAddress("MCD_PAUSE_PROXY");
        susds = SUsdsLike(LOG.getAddress("SUSDS"));
        usds = UsdsLike(LOG.getAddress("USDS"));

        VentureInstance memory inst = VentureDeploy.deploy(address(this), pauseProxy);
        token = Venture(inst.venture);
        handler = VentureHandler(inst.handler);
        VentureConfig memory conf = VentureConfig({
            handlerBuffer: address(0xC0FFEE),
            handlerLockTimeBgn: 13 hours,
            handlerLockTimeEnd: 14 hours,
            handlerSettleTime:  16 hours,
            beamMaxMint: 100_000e18,
            beamMaxCut:  100_000e18,
            beamMaxDepositCapacity:  100_000e18,
            beamMaxWithdrawCapacity: 100_000e18,
            beamHop: 7 days,
            beamBuds: new address[](0)
        });
        vm.startPrank(pauseProxy);
        VentureInit.init(dss, inst, conf);
        token.rely(address(this)); // To be able to mint and burn
        vm.stopPrank();
        assertEq(token.chi(), RAY);
        assertEq(token.rho(), block.timestamp);
        assertEq(token.wards(pauseProxy), 1);
        assertEq(token.version(), "1");
        assertEq(token.getImplementation(), inst.ventureImp);

        // The token holds nothing: shares are minted against backing held by the handler's buffer
        token.mint(100e18, address(0x222));

        token.settle(2e18);

        assertEq(token.chi(), 1.02e27);
    }

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // Note: _divup(0,0) will return 0 differing from natural solidity division
        unchecked {
            z = x != 0 ? ((x - 1) / y) + 1 : 0;
        }
    }

    function testDeployWithUpgradesLib() public {
        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.unsafeAllow = 'constructor';
        }

        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        address proxy = Upgrades.deployUUPSProxy(
            "out/Venture.sol/Venture.json",
            abi.encodeCall(Venture.initialize, ()),
            opts
        );
        assertEq(Venture(proxy).version(), "1");
        assertEq(Venture(proxy).wards(address(this)), 1);
    }

    function testUpgrade() public {
        address implementation1 = token.getImplementation();

        address newImpl = address(new Venture2());
        vm.startPrank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        token.upgradeToAndCall(newImpl, abi.encodeCall(Venture2.reinitialize, ()));
        vm.stopPrank();

        address implementation2 = token.getImplementation();
        assertEq(implementation2, newImpl);
        assertTrue(implementation2 != implementation1);
        assertEq(token.version(), "2");
        assertEq(token.wards(address(pauseProxy)), 1); // still a ward
    }

    function testUpgradeWithUpgradesLib() public {
        address implementation1 = token.getImplementation();

        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.referenceContract = "out/Venture.sol/Venture.json";
            opts.unsafeAllow = 'constructor';
        }

        vm.startPrank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        Upgrades.upgradeProxy(
            address(token),
            "out/Venture-integration.t.sol/Venture2.json",
            abi.encodeCall(Venture2.reinitialize, ()),
            opts
        );
        vm.stopPrank();

        address implementation2 = token.getImplementation();
        assertTrue(implementation1 != implementation2);
        assertEq(token.version(), "2");
        assertEq(token.wards(address(pauseProxy)), 1); // still a ward
    }

    function testUpgradeUnauthed() public {
        address newImpl = address(new Venture2());
        vm.expectRevert("Venture/not-authorized");
        vm.prank(address(0x123)); token.upgradeToAndCall(newImpl, abi.encodeCall(Venture2.reinitialize, ()));
    }

    function testInitializeAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize();
    }

    function testInitializeDirectly() public {
        address implementation = token.getImplementation();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Venture(implementation).initialize();
    }

    function testConstructor() public {
        address imp = address(new Venture());
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        Venture token2 = Venture(address(new ERC1967Proxy(imp, abi.encodeCall(Venture.initialize, ()))));
        assertEq(token2.name(), "Venture Unit");
        assertEq(token2.symbol(), "vUNIT");
        assertEq(token2.version(), "1");
        assertEq(token2.decimals(), 18);
        assertEq(token2.chi(), RAY);
        assertEq(token2.rho(), block.timestamp);
        assertEq(token2.wards(address(this)), 1);
        assertEq(token2.totalSupply(), 0);
        assertEq(token2.totalAssets(), 0);
    }

    function testAuth() public {
        checkAuth(address(token), "Venture");
    }

    function testERC20() public {
        checkBulkERC20(address(token), "Venture", "Venture Unit", "vUNIT", "1", 18);
    }

    function testPermit() public {
        checkBulkPermit(address(token), "Venture");
    }

    function testConversion() public {
        uint256 pshares = token.convertToShares(1e18);
        uint256 passets = token.convertToAssets(pshares);

        // Converting back and forth should always round against
        assertLe(passets, 1e18);

        // Accrue some interest
        token.settle(0.1e18);

        uint256 shares = token.convertToShares(1e18);

        // Shares should be less because more interest has accrued
        assertLt(shares, pshares);
    }

    uint256 chiBefore;
    uint256 chiAfter;

    function testMint() public {
        uint256 prevSupply = token.totalSupply();
        uint256 prevAssets = token.totalAssets();

        uint256 pie = 1e18 * RAY / token.chi();
        vm.expectEmit();
        emit Transfer(address(0), address(0xBEEF), pie);
        token.mint(pie, address(0xBEEF));

        assertEq(token.totalSupply(), prevSupply + pie);
        assertEq(token.balanceOf(address(0xBEEF)), pie);

        // Minting raises the claim without any asset moving here
        assertLe(token.totalAssets(), prevAssets + 1e18); // May be slightly less due to rounding error
        assertGe(token.totalAssets(), prevAssets + 1e18 - 1);
        assertEq(susds.balanceOf(address(token)), 0);
    }

    function testMintBadAddress() public {
        vm.expectRevert("Venture/invalid-address");
        token.mint(1e18, address(0));
        vm.expectRevert("Venture/invalid-address");
        token.mint(1e18, address(token));
    }

    function testMintUnauthed() public {
        vm.expectRevert("Venture/not-authorized");
        vm.prank(address(0x123)); token.mint(1e18, address(0xBEEF));
    }

    function testBurn() public {
        uint256 prevSupply = token.totalSupply();

        chiBefore = token.chi();
        uint256 pie = 10e18 * RAY / chiBefore;
        chiAfter = chiBefore * ((prevSupply + pie) * chiBefore / RAY + 5e18) / ((prevSupply + pie) * chiBefore / RAY);
        assertGt(chiAfter, chiBefore);

        token.mint(pie, address(0xBEEF));

        token.settle(5e18);
        assertEq(token.chi(), chiAfter);

        uint256 burned = pie * 0.1e18 / WAD;

        token.rely(address(0xBEEF)); // To be able to burn
        vm.expectEmit();
        emit Transfer(address(0xBEEF), address(0), burned);
        vm.prank(address(0xBEEF)); token.burn(burned, address(0xBEEF));

        assertEq(token.totalSupply(), prevSupply + pie - burned);
        assertEq(token.balanceOf(address(0xBEEF)), pie - burned);
        assertEq(susds.balanceOf(address(token)), 0);
    }

    function testBurnUnauthed() public {
        token.mint(1e18, address(0xBEEF));

        vm.expectRevert("Venture/not-authorized");
        vm.prank(address(0x123)); token.burn(1e18, address(0xBEEF));
    }

    function testBurnWithoutApprovalReverts() public {
        token.mint(1e18, address(0xBEEF));

        // A ward still cannot burn a third party's shares without an allowance
        token.rely(address(0xAAA));
        vm.expectRevert("Venture/insufficient-allowance");
        vm.prank(address(0xAAA)); token.burn(1e18, address(0xBEEF));
    }

    function testERC20Fuzz(
        address from,
        address to,
        uint256 amount1,
        uint256 amount2
    ) public {
        checkBulkERC20Fuzz(address(token), "Venture", from, to, amount1, amount2);
    }

    function testPermitFuzz(
        uint128 privKey,
        address to,
        uint256 amount,
        uint256 deadline,
        uint256 nonce
    ) public {
        checkBulkPermitFuzz(address(token), "Venture", privKey, to, amount, deadline, nonce);
    }

    function testSettlePositive() public {
        uint256 senderSusds = susds.balanceOf(address(pauseProxy));
        uint256 totalAssets = token.totalAssets();
        chiBefore = token.chi();
        chiAfter = chiBefore * (totalAssets + 50e18) / totalAssets;

        vm.expectEmit();
        emit Settle(50e18, chiBefore, chiAfter);
        vm.prank(pauseProxy); token.settle(50e18);

        // Revaluation only: the backing lives with the handler's buffer
        assertEq(token.chi(), chiAfter);
        assertEq(token.totalAssets(), totalAssets + 50e18);
        assertEq(susds.balanceOf(address(token)), 0);
        assertEq(susds.balanceOf(address(pauseProxy)), senderSusds);
    }

    function testSettleNegative() public {
        uint256 senderSusds = susds.balanceOf(address(pauseProxy));
        uint256 totalAssets = token.totalAssets();
        chiBefore = token.chi();
        chiAfter = chiBefore * (totalAssets - 50e18) / totalAssets;

        vm.expectEmit();
        emit Settle(-50e18, chiBefore, chiAfter);
        vm.prank(pauseProxy); token.settle(-50e18);

        assertEq(token.chi(), chiAfter);
        assertEq(token.totalAssets(), totalAssets - 50e18);
        assertEq(susds.balanceOf(address(token)), 0);
        assertEq(susds.balanceOf(address(pauseProxy)), senderSusds);
    }

    function testSettleNoSupplyKeepsChi() public {
        Venture token2 = Venture(address(new ERC1967Proxy(address(new Venture()), abi.encodeCall(Venture.initialize, ()))));

        // No shares outstanding: chi must survive, since it divides every conversion
        token2.settle(50e18);
        assertEq(token2.chi(), RAY);

        token2.settle(-50e18);
        assertEq(token2.chi(), RAY);
    }

    function testSettleTotalLossKeepsChiNonZero() public {
        token.settle(-int256(token.totalAssets()));

        assertEq(token.chi(), 1);
    }
}
