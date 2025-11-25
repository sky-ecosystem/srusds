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

import { SrUsds, UUPSUpgradeable, Initializable, ERC1967Utils } from "src/SrUsds.sol";
import { SrUsdsHandler } from "src/SrUsdsHandler.sol";

import { SrUsdsInstance } from "deploy/SrUsdsInstance.sol";
import { SrUsdsDeploy } from "deploy/SrUsdsDeploy.sol";
import { SrUsdsInit, SrUsdsConfig } from "deploy/SrUsdsInit.sol";

interface SUsdsLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

interface UsdsLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

contract SrUsds2 is UUPSUpgradeable {
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
        require(wards[msg.sender] == 1, "SrUsds/not-authorized");
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

contract SrUsdsIntegrationTest is TokenFuzzChecks {

    using GodMode for *;

    ChainlogAbstract LOG;

    DssInstance dss;
    address pauseProxy;
    address susdsJoin;
    SUsdsLike susds;
    UsdsLike usds;

    SrUsds token;
    SrUsdsHandler handler;
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
        susdsJoin = LOG.getAddress("USDS_JOIN");

        SrUsdsInstance memory inst = SrUsdsDeploy.deploy(address(this), pauseProxy);
        token = SrUsds(inst.srUsds);
        handler = SrUsdsHandler(inst.handler);
        SrUsdsConfig memory conf = SrUsdsConfig({
            handlerHop: 7 days,
            settlerZzz: 10,
            settlerMaxMint: 100_000e18,
            settlerMaxCut: 100_000e18,
            settlerBuds: new address[](0)
        });
        vm.startPrank(pauseProxy);
        SrUsdsInit.init(dss, inst, conf);
        token.rely(address(this)); // To be able to deposit and withdraw
        vm.stopPrank();
        assertEq(token.chi(), RAY);
        assertEq(token.rho(), block.timestamp);
        assertEq(token.wards(pauseProxy), 1);
        assertEq(token.version(), "1");
        assertEq(token.getImplementation(), inst.srUsdsImp);

        assertEq(dss.vat.can(address(handler), susdsJoin), 1);

        deal(address(susds), address(this), 200e18);
        susds.approve(address(token), type(uint256).max);
        token.deposit(100e18, address(0x222));

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
            opts.unsafeAllow = 'state-variable-immutable,constructor';
        }
        opts.constructorData = abi.encode(
                                    address(susds)
                                    );

        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        address proxy = Upgrades.deployUUPSProxy(
            "out/SrUsds.sol/SrUsds.json",
            abi.encodeCall(SrUsds.initialize, ()),
            opts
        );
        assertEq(SrUsds(proxy).version(), "1");
        assertEq(SrUsds(proxy).wards(address(this)), 1);
    }

    function testUpgrade() public {
        address implementation1 = token.getImplementation();

        address newImpl = address(new SrUsds2());
        vm.startPrank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        token.upgradeToAndCall(newImpl, abi.encodeCall(SrUsds2.reinitialize, ()));
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
            opts.referenceContract = "out/SrUsds.sol/SrUsds.json";
            opts.unsafeAllow = 'constructor';
        }

        vm.startPrank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit UpgradedTo("2");
        Upgrades.upgradeProxy(
            address(token),
            "out/SrUsds-integration.t.sol/SrUsds2.json",
            abi.encodeCall(SrUsds2.reinitialize, ()),
            opts
        );
        vm.stopPrank();

        address implementation2 = token.getImplementation();
        assertTrue(implementation1 != implementation2);
        assertEq(token.version(), "2");
        assertEq(token.wards(address(pauseProxy)), 1); // still a ward
    }

    function testUpgradeUnauthed() public {
        address newImpl = address(new SrUsds2());
        vm.expectRevert("SrUsds/not-authorized");
        vm.prank(address(0x123)); token.upgradeToAndCall(newImpl, abi.encodeCall(SrUsds2.reinitialize, ()));
    }

    function testInitializeAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize();
    }

    function testInitializeDirectly() public {
        address implementation = token.getImplementation();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SrUsds(implementation).initialize();
    }

    function testConstructor() public {
        address imp = address(new SrUsds(address(susds)));
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        SrUsds token2 = SrUsds(address(new ERC1967Proxy(imp, abi.encodeCall(SrUsds.initialize, ()))));
        assertEq(token2.name(), "Senior Risk USDS");
        assertEq(token2.symbol(), "srUSDS");
        assertEq(token2.version(), "1");
        assertEq(token2.decimals(), 18);
        assertEq(token2.chi(), RAY);
        assertEq(token2.rho(), block.timestamp);
        assertEq(token2.wards(address(this)), 1);
        assertEq(address(token2.susds()), address(susds));
        assertEq(address(token2.asset()), address(susds));
    }

    function testAuth() public {
        checkAuth(address(token), "SrUsds");
    }

    function testERC20() public {
        checkBulkERC20(address(token), "SrUsds", "Senior Risk USDS", "srUSDS", "1", 18);
    }

    function testPermit() public {
        checkBulkPermit(address(token), "SrUsds");
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

    function testDeposit() public {
        uint256 prevSupply = token.totalSupply();
        uint256 srusdsSusds = susds.balanceOf(address(token));

        uint256 pie = 1e18 * RAY / token.chi();
        vm.expectEmit();
        emit Deposit(address(this), address(0xBEEF), 1e18, pie);
        vm.expectEmit();
        emit Transfer(address(0), address(0xBEEF), pie);
        token.deposit(1e18, address(0xBEEF));

        assertEq(token.totalSupply(), prevSupply + pie);
        assertLe(token.totalAssets(), srusdsSusds + 1e18); // May be slightly less due to rounding error
        assertGe(token.totalAssets(), srusdsSusds + 1e18 - 1);
        assertEq(token.balanceOf(address(0xBEEF)), pie);
        assertEq(susds.balanceOf(address(token)), srusdsSusds + _divup(pie * token.chi(), RAY));
    }

    function testDepositBadAddress() public {
        vm.expectRevert("SrUsds/invalid-address");
        token.deposit(1e18, address(0));
        vm.expectRevert("SrUsds/invalid-address");
        token.deposit(1e18, address(token));
    }

    function testRedeem() public {
        uint256 prevSupply = token.totalSupply();
        uint256 srusdsSusds = susds.balanceOf(address(token));

        chiBefore = token.chi();
        uint256 pie = 10e18 * RAY / chiBefore;
        chiAfter = token.chi() * ((prevSupply + pie) * chiBefore / RAY + 5e18) / ((prevSupply + pie) * chiBefore / RAY);
        assertGt(chiAfter, chiBefore);

        token.deposit(10e18, address(0xBEEF));

        assertEq(susds.balanceOf(address(token)), srusdsSusds + _divup(pie * chiBefore, RAY));

        token.settle(5e18);
        assertEq(token.chi(), chiAfter);

        token.rely(address(0xBEEF)); // To be able to redeem
        vm.expectEmit();
        emit Transfer(address(0xBEEF), address(0), pie * 0.1e18 / WAD);
        vm.expectEmit();
        emit Withdraw(address(0xBEEF), address(0xAAA), address(0xBEEF), (pie * 0.1e18 / WAD) * chiAfter / RAY, pie * 0.1e18 / WAD);
        vm.prank(address(0xBEEF)); token.redeem(pie * 0.1e18 / WAD, address(0xAAA), address(0xBEEF));
        
        assertEq(token.totalSupply(), prevSupply + pie - pie * 0.1e18 / WAD);
        assertEq(token.balanceOf(address(0xBEEF)), pie - pie * 0.1e18 / WAD);
        assertEq(susds.balanceOf(address(0xAAA)), (pie * 0.1e18 / WAD) * chiAfter / RAY);
        assertEq(susds.balanceOf(address(token)), srusdsSusds + _divup(pie * chiBefore, RAY) + 5e18 - (pie * 0.1e18 / WAD) * chiAfter / RAY);
    }

    function testERC20Fuzz(
        address from,
        address to,
        uint256 amount1,
        uint256 amount2
    ) public {
        checkBulkERC20Fuzz(address(token), "SrUsds", from, to, amount1, amount2);
    }

    function testPermitFuzz(
        uint128 privKey,
        address to,
        uint256 amount,
        uint256 deadline,
        uint256 nonce
    ) public {
        checkBulkPermitFuzz(address(token), "SrUsds", privKey, to, amount, deadline, nonce);
    }

    function testSettlePositive() public {
        deal(address(susds), address(pauseProxy), 50e18);
        vm.prank(pauseProxy); susds.approve(address(token), 50e18);
        uint256 senderUsds = susds.balanceOf(address(pauseProxy));
        uint256 srusdsUsds = susds.balanceOf(address(token));
        uint256 totalAssets = token.totalAssets();
        assertLe(totalAssets, srusdsUsds);
        chiBefore = token.chi();
        chiAfter = chiBefore * (totalAssets + 50e18) / totalAssets;

        vm.expectEmit();
        emit Settle(50e18, chiBefore, chiAfter);
        vm.prank(pauseProxy); token.settle(50e18);

        assertEq(susds.balanceOf(address(token)), srusdsUsds + 50e18);
        assertEq(susds.balanceOf(address(pauseProxy)), senderUsds - 50e18);
        assertEq(token.chi(), chiAfter);
        assertEq(token.totalAssets(), totalAssets + 50e18);
    }

    function testSettleNegative() public {
        uint256 senderUsds = susds.balanceOf(address(pauseProxy));
        uint256 srusdsUsds = susds.balanceOf(address(token));
        uint256 totalAssets = token.totalAssets();
        assertLe(totalAssets, srusdsUsds);
        chiBefore = token.chi();
        chiAfter = chiBefore * (totalAssets - 50e18) / totalAssets;

        vm.expectEmit();
        emit Settle(-50e18, chiBefore, chiAfter);
        vm.prank(pauseProxy); token.settle(-50e18);

        assertEq(susds.balanceOf(address(token)), srusdsUsds - 50e18);
        assertEq(susds.balanceOf(address(pauseProxy)), senderUsds + 50e18);
        assertEq(token.chi(), chiAfter);
        assertEq(token.totalAssets(), totalAssets - 50e18);
    }
}
