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
import { SrUsdsQueues } from "src/SrUsdsQueues.sol";
import { SrUsdsBeam } from "src/SrUsdsBeam.sol";
import { SrUsdsMom } from "src/SrUsdsMom.sol";

import { SrUsdsInstance } from "deploy/SrUsdsInstance.sol";
import { SrUsdsDeploy } from "deploy/SrUsdsDeploy.sol";
import { SrUsdsInit, SrUsdsConfig } from "deploy/SrUsdsInit.sol";

interface SUsdsLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function previewMint(uint256) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
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
    address chief;
    address usdsJoin;
    address vow;
    SUsdsLike susds;

    SrUsds       token;
    SrUsdsQueues queues;
    SrUsdsBeam   beam;
    SrUsdsMom    mom;
    SrUsdsInstance inst;
    bool validate;

    address bud   = address(0xB0D);
    address alice = address(0xA11CE);

    event Settle(int256 assets, uint256 oldChi, uint256 newChi);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event UpgradedTo(string version);
    event HaltBeam(address indexed beam);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 10 hours); // Outside the settlement window, whatever the time of day
        validate = vm.envOr("VALIDATE", false);

        LOG = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
        dss = MCD.loadFromChainlog(LOG);

        pauseProxy = LOG.getAddress("MCD_PAUSE_PROXY");
        chief      = LOG.getAddress("MCD_ADM");
        susds      = SUsdsLike(LOG.getAddress("SUSDS"));
        usdsJoin   = LOG.getAddress("USDS_JOIN");
        vow        = LOG.getAddress("MCD_VOW");

        inst   = SrUsdsDeploy.deploy(address(this), pauseProxy);
        token  = SrUsds(inst.srUsds);
        queues = SrUsdsQueues(inst.queues);
        beam   = SrUsdsBeam(inst.beam);
        mom    = SrUsdsMom(inst.mom);
        address[] memory buds = new address[](1);
        buds[0] = bud;
        SrUsdsConfig memory conf = SrUsdsConfig({
            lockTimeBgn:        13 hours,
            lockTimeEnd:        16 hours,
            period:             1,
            startDay:           block.timestamp / 1 days,
            maxMint:            100_000e18,
            maxCut:             100_000e18,
            maxDepositCapacity: 100_000e18,
            maxRedeemCapacity:  100_000e18,
            buds:               buds
        });
        vm.startPrank(pauseProxy);
        SrUsdsInit.init(dss, inst, conf);
        token.rely(address(this)); // To be able to deposit and redeem directly
        vm.stopPrank();

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

    function _warpToWindow() internal {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 14 hours);
    }

    // --- Deployment ---

    function testDeployAndInit() public {
        // SrUsds
        assertEq(token.chi(), 1.02e27);
        assertEq(token.wards(pauseProxy), 1);
        assertEq(token.wards(inst.queues), 1);
        assertEq(token.version(), "1");
        assertEq(token.getImplementation(), inst.srUsdsImp);
        assertEq(address(token.usdsJoin()), usdsJoin);
        assertEq(token.vow(), vow);
        assertEq(address(token.susds()), address(susds));
        assertEq(dss.vat.wards(address(token)), 1);
        assertEq(dss.vat.can(address(token), usdsJoin), 1);

        // Queues
        assertEq(queues.wards(pauseProxy), 1);
        assertEq(queues.wards(inst.beam), 1);
        assertEq(queues.wards(address(this)), 0);
        assertEq(queues.getImplementation(), inst.queuesImp);
        assertEq(address(queues.share()), inst.srUsds);
        assertEq(address(queues.asset()), address(susds));
        assertEq(queues.lockTimeBgn(), 13 hours);
        assertEq(queues.lockTimeEnd(), 16 hours);
        assertEq(queues.period(), 1);
        assertEq(queues.startDay(), block.timestamp / 1 days);

        // Beam
        assertEq(beam.wards(pauseProxy), 1);
        assertEq(beam.wards(inst.mom), 1);
        assertEq(beam.wards(address(this)), 0);
        assertEq(address(beam.queues()), inst.queues);
        assertEq(beam.buds(bud), 1);
        assertEq(beam.maxMint(), 100_000e18);
        assertEq(beam.maxCut(), 100_000e18);
        assertEq(beam.maxDepositCapacity(), 100_000e18);
        assertEq(beam.maxRedeemCapacity(), 100_000e18);
        assertEq(beam.bad(), 0);

        // Mom
        assertEq(mom.owner(), pauseProxy);
        assertEq(mom.authority(), chief);

        // Chainlog
        assertEq(LOG.getAddress("SRUSDS"), inst.srUsds);
        assertEq(LOG.getAddress("SRUSDS_IMP"), inst.srUsdsImp);
        assertEq(LOG.getAddress("SRUSDS_QUEUES"), inst.queues);
        assertEq(LOG.getAddress("SRUSDS_QUEUES_IMP"), inst.queuesImp);
        assertEq(LOG.getAddress("SRUSDS_BEAM"), inst.beam);
        assertEq(LOG.getAddress("SRUSDS_MOM"), inst.mom);
    }

    function testDeployWithUpgradesLib() public {
        Options memory opts;
        if (!validate) {
            opts.unsafeSkipAllChecks = true;
        } else {
            opts.unsafeAllow = 'state-variable-immutable,constructor';
        }
        opts.constructorData = abi.encode(usdsJoin, vow, address(susds));

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
        assertEq(token.chi(), 1.02e27);                // storage kept
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

    function testUpgradeQueues() public {
        address implementation1 = queues.getImplementation();
        address newImpl = address(new SrUsdsQueues(address(token)));

        vm.expectRevert("SrUsdsQueues/not-authorized");
        vm.prank(address(0x123)); queues.upgradeToAndCall(newImpl, "");

        vm.prank(pauseProxy); queues.upgradeToAndCall(newImpl, "");
        assertEq(queues.getImplementation(), newImpl);
        assertTrue(newImpl != implementation1);
        assertEq(queues.wards(pauseProxy), 1);
        assertEq(queues.lockTimeBgn(), 13 hours); // storage kept
    }

    function testInitializeAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        queues.initialize();
    }

    function testInitializeDirectly() public {
        SrUsds tokenImp = SrUsds(token.getImplementation());
        SrUsdsQueues queuesImp = SrUsdsQueues(queues.getImplementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        tokenImp.initialize();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        queuesImp.initialize();
    }

    function testConstructor() public {
        address imp = address(new SrUsds(usdsJoin, vow, address(susds)));
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        SrUsds token2 = SrUsds(address(new ERC1967Proxy(imp, abi.encodeCall(SrUsds.initialize, ()))));
        assertEq(token2.name(), "Senior Risk USDS");
        assertEq(token2.symbol(), "srUSDS");
        assertEq(token2.version(), "1");
        assertEq(token2.decimals(), 18);
        assertEq(token2.chi(), RAY);
        assertEq(token2.wards(address(this)), 1);
        assertEq(address(token2.usdsJoin()), usdsJoin);
        assertEq(address(token2.vat()), address(dss.vat));
        assertEq(token2.vow(), vow);
        assertEq(address(token2.susds()), address(susds));
        assertEq(address(token2.asset()), address(susds));
        assertEq(dss.vat.can(address(token2), usdsJoin), 1);
    }

    // --- Token ---

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

        // Book a gain
        token.settle(0.1e18);

        uint256 shares = token.convertToShares(1e18);

        // Shares should be less because the price went up
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
        assertEq(susds.balanceOf(address(token)), srusdsSusds + 1e18);
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
        token.deposit(10e18, address(0xBEEF));
        assertEq(susds.balanceOf(address(token)), srusdsSusds + 10e18);

        chiAfter = chiBefore + 5e18 * RAY / (prevSupply + pie);
        token.settle(5e18);
        assertEq(token.chi(), chiAfter);

        token.rely(address(0xBEEF)); // To be able to redeem
        uint256 redeemed = pie * 0.1e18 / WAD;
        vm.expectEmit();
        emit Transfer(address(0xBEEF), address(0), redeemed);
        vm.expectEmit();
        emit Withdraw(address(0xBEEF), address(0xAAA), address(0xBEEF), redeemed * chiAfter / RAY, redeemed);
        vm.prank(address(0xBEEF)); token.redeem(redeemed, address(0xAAA), address(0xBEEF));

        assertEq(token.totalSupply(), prevSupply + pie - redeemed);
        assertEq(token.balanceOf(address(0xBEEF)), pie - redeemed);
        assertEq(susds.balanceOf(address(0xAAA)), redeemed * chiAfter / RAY);
        assertEq(susds.balanceOf(address(token)), srusdsSusds + 10e18 + 5e18 - redeemed * chiAfter / RAY);
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

    /// A gain is generated as USDS against the vow and converted into exactly that much sUSDS
    function testSettlePositive() public {
        uint256 srusdsSusds = susds.balanceOf(address(token));
        uint256 totalAssets = token.totalAssets();
        uint256 sinBefore = dss.vat.sin(vow);
        uint256 usdsAmt = susds.previewMint(50e18);
        assertLe(totalAssets, srusdsSusds);
        chiBefore = token.chi();
        chiAfter = chiBefore + 50e18 * RAY / token.totalSupply();

        vm.expectEmit();
        emit Settle(50e18, chiBefore, chiAfter);
        vm.prank(pauseProxy); token.settle(50e18);

        assertEq(susds.balanceOf(address(token)), srusdsSusds + 50e18);
        assertEq(dss.vat.sin(vow), sinBefore + usdsAmt * RAY);
        assertEq(token.chi(), chiAfter);
        assertLe(token.totalAssets(), totalAssets + 50e18);
        assertGe(token.totalAssets(), totalAssets + 50e18 - 1);
    }

    /// A loss is redeemed from the backing and returned to the vow
    function testSettleNegative() public {
        uint256 srusdsSusds = susds.balanceOf(address(token));
        uint256 totalAssets = token.totalAssets();
        uint256 daiBefore = dss.vat.dai(vow);
        uint256 usdsAmt = susds.previewRedeem(50e18);
        assertLe(totalAssets, srusdsSusds);
        chiBefore = token.chi();
        chiAfter = chiBefore - _divup(50e18 * RAY, token.totalSupply());

        vm.expectEmit();
        emit Settle(-50e18, chiBefore, chiAfter);
        vm.prank(pauseProxy); token.settle(-50e18);

        assertEq(susds.balanceOf(address(token)), srusdsSusds - 50e18);
        assertEq(dss.vat.dai(vow), daiBefore + usdsAmt * RAY);
        assertEq(token.chi(), chiAfter);
        assertLe(token.totalAssets(), totalAssets - 50e18);
        assertGe(token.totalAssets(), totalAssets - 50e18 - 1);
    }

    // --- Queues, Beam and Mom ---

    /// A deposit queued by a user, settled by the facilitator through the Beam, claimed as srUSDS, queued for
    /// redemption and claimed back as sUSDS
    function testQueueFlow() public {
        deal(address(susds), alice, 10e18);
        vm.startPrank(alice);
        susds.approve(address(queues), 10e18);
        queues.queueDeposit(10e18, alice, alice, 0);
        vm.stopPrank();
        assertEq(queues.pendingDeposit(alice), 10e18);

        _warpToWindow();
        assertTrue(queues.locked());
        chiBefore = token.chi();
        vm.prank(bud); beam.settle(1e18, 10e18, 0);
        assertFalse(queues.locked());
        assertEq(token.chi(), chiBefore + 1e18 * RAY / (token.totalSupply() - token.balanceOf(address(queues)))); // Revalued before converting
        uint256 shares = 10e18 * RAY / token.chi();
        assertEq(queues.claimableDeposit(alice), shares);
        assertEq(queues.pendingDeposit(alice), 0);

        vm.startPrank(alice);
        assertEq(queues.claimDeposit(type(uint256).max, alice, alice), shares);
        assertEq(token.balanceOf(alice), shares);
        token.approve(address(queues), shares);
        queues.queueRedeem(shares, alice, alice);
        vm.stopPrank();
        assertEq(queues.pendingRedeem(alice), shares);

        _warpToWindow();
        vm.prank(bud); beam.settle(0, 0, shares);
        uint256 assets = queues.claimableRedeem(alice);
        assertApproxEqAbs(assets, shares * token.chi() / RAY, 1); // The reward per share and its credit both round down
        vm.prank(alice); assertEq(queues.claimRedeem(type(uint256).max, alice, alice), assets);
        assertEq(susds.balanceOf(alice), assets);
        assertGe(assets, 10e18 - 2); // A wei to the share price rounding, a wei to the queue's
    }

    function testBeamLimits() public {
        _warpToWindow();
        vm.startPrank(bud);
        vm.expectRevert("SrUsdsBeam/maxMint-exceed");
        beam.settle(100_000e18 + 1, 0, 0);
        vm.expectRevert("SrUsdsBeam/maxCut-exceed");
        beam.settle(-100_000e18 - 1, 0, 0);
        vm.expectRevert("SrUsdsBeam/maxDepositCapacity-exceed");
        beam.settle(0, 100_000e18 + 1, 0);
        vm.expectRevert("SrUsdsBeam/maxRedeemCapacity-exceed");
        beam.settle(0, 0, 100_000e18 + 1);
        vm.stopPrank();

        vm.expectRevert("SrUsdsBeam/not-facilitator");
        beam.settle(0, 0, 0);
        vm.expectRevert("SrUsdsQueues/not-authorized"); // Only the Beam settles the queues (and governance)
        queues.settle(0, 0, 0);

        vm.prank(bud); beam.settle(0, 0, 0);
        assertEq(queues.lastSettleDay(), block.timestamp / 1 days);
    }

    /// Governance can halt the Beam through the Mom without delay, and only governance lifts it
    function testHaltBeam() public {
        vm.expectRevert("SrUsdsMom/not-authorized");
        mom.haltBeam(address(beam));

        vm.prank(pauseProxy);
        vm.expectEmit();
        emit HaltBeam(address(beam));
        mom.haltBeam(address(beam));
        assertEq(beam.bad(), 1);

        _warpToWindow();
        vm.prank(bud); vm.expectRevert("SrUsdsBeam/module-halted");
        beam.settle(0, 0, 0);

        vm.prank(pauseProxy); queues.settle(0, 0, 0); // Governance can still settle directly
        assertFalse(queues.locked());

        vm.prank(pauseProxy); beam.file("bad", 0);
        assertEq(beam.bad(), 0);
    }
}
