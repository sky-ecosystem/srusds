// SPDX-FileCopyrightText: © 2023 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
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

pragma solidity >=0.8.0;

import { DssInstance } from "dss-test/MCD.sol";
import { VentureInstance } from "./VentureInstance.sol";

interface VentureLike {
    function version() external view returns (string memory);
    function getImplementation() external view returns (address);
    function rely(address) external;
}

interface HandlerLike {
    function venture() external view returns (address);
    function gem() external view returns (address);
    function buffer() external view returns (address);
    function file(bytes32, uint256) external;
    function file(bytes32, address) external;
    function rely(address) external;
}

interface BeamLike {
    function handler() external view returns (address);
    function file(bytes32, uint256) external;
    function kiss(address) external;
    function rely(address) external;
}

interface VentureMomLike {
    function handler() external view returns (address);
    function setAuthority(address) external;
}

struct VentureConfig {
    address   handlerBuffer;
    uint256   handlerLockTimeBgn;
    uint256   handlerLockTimeEnd;
    uint256   handlerSettleTime;
    uint256   beamMaxMint;
    uint256   beamMaxCut;
    uint256   beamMaxDepositCapacity;
    uint256   beamMaxWithdrawCapacity;
    uint256   beamHop;
    address[] beamBuds;
}

library VentureInit {

    uint256 constant internal RAY = 10**27;

    function init(
        DssInstance   memory dss,
        VentureInstance memory instance,
        VentureConfig   memory cfg
    ) internal {
        // --- Validate Venture ---
        require(keccak256(abi.encodePacked(VentureLike(instance.venture).version())) == keccak256(abi.encodePacked("1")), "VentureInit/version-does-not-match");
        require(VentureLike(instance.venture).getImplementation() == instance.ventureImp, "VentureInit/imp-does-not-match");

        // --- Validate Handler ---
        require(HandlerLike(instance.handler).venture() == instance.venture, "VentureInit/handler-venture-mismatch");
        require(HandlerLike(instance.handler).gem() == dss.chainlog.getAddress("SUSDS"), "VentureInit/handler-gem-mismatch");

        // --- Validate Config ---
        require(cfg.handlerBuffer != address(0), "VentureInit/buffer-zero-address");

        // --- Validate Beam ---
        require(BeamLike(instance.beam).handler() == instance.handler, "VentureInit/beam-handler-mismatch");

        // --- Validate Mom ---
        require(VentureMomLike(instance.mom).handler() == instance.handler, "VentureInit/mom-handler-mismatch");

        // --- Configure Venture permissions ---
        // Handler needs auth to call settle(), mint() and burn()
        VentureLike(instance.venture).rely(instance.handler);

        // --- Configure Handler ---
        HandlerLike(instance.handler).file("buffer", cfg.handlerBuffer);
        HandlerLike(instance.handler).file("settleTime",  cfg.handlerSettleTime);
        HandlerLike(instance.handler).file("lockTimeEnd", cfg.handlerLockTimeEnd);
        HandlerLike(instance.handler).file("lockTimeBgn", cfg.handlerLockTimeBgn);
        HandlerLike(instance.handler).rely(instance.beam);
        HandlerLike(instance.handler).rely(instance.mom);

        // --- Configure Beam ---
        BeamLike(instance.beam).rely(instance.mom);
        BeamLike(instance.beam).file("maxMint", cfg.beamMaxMint);
        BeamLike(instance.beam).file("maxCut", cfg.beamMaxCut);
        BeamLike(instance.beam).file("maxDepositCapacity", cfg.beamMaxDepositCapacity);
        BeamLike(instance.beam).file("maxWithdrawCapacity", cfg.beamMaxWithdrawCapacity);
        BeamLike(instance.beam).file("hop", cfg.beamHop);

        for (uint256 i; i < cfg.beamBuds.length; i++) {
            BeamLike(instance.beam).kiss(cfg.beamBuds[i]);
        }

        // --- Configure Mom ---
        VentureMomLike(instance.mom).setAuthority(dss.chainlog.getAddress("MCD_ADM"));

        // --- Update Chainlog ---
        dss.chainlog.setAddress("VENTURE",         instance.venture);
        dss.chainlog.setAddress("VENTURE_IMP",     instance.ventureImp);
        dss.chainlog.setAddress("VENTURE_HANDLER", instance.handler);
        dss.chainlog.setAddress("VENTURE_BEAM",    instance.beam);
        dss.chainlog.setAddress("VENTURE_MOM",     instance.mom);
    }
}
