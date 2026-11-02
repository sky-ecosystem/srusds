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
import { SrUsdsInstance } from "./SrUsdsInstance.sol";

interface SrUsdsLike {
    function version() external view returns (string memory);
    function getImplementation() external view returns (address);
    function usdsJoin() external view returns (address);
    function vow() external view returns (address);
    function susds() external view returns (address);
    function rely(address) external;
}

interface QueuesLike {
    function getImplementation() external view returns (address);
    function share() external view returns (address);
    function asset() external view returns (address);
    function file(bytes32, uint256) external;
    function rely(address) external;
}

interface BeamLike {
    function queues() external view returns (address);
    function file(bytes32, uint256) external;
    function kiss(address) external;
    function rely(address) external;
}

interface MomLike {
    function setAuthority(address) external;
}

struct SrUsdsConfig {
    uint256   lockTimeBgn;
    uint256   lockTimeEnd;
    uint256   period;
    uint256   startDay;
    uint256   maxMint;
    uint256   maxCut;
    uint256   maxDepositCapacity;
    uint256   maxRedeemCapacity;
    address[] buds;
}

library SrUsdsInit {

    function init(
        DssInstance    memory dss,
        SrUsdsInstance memory instance,
        SrUsdsConfig   memory cfg
    ) internal {
        address susds = dss.chainlog.getAddress("SUSDS");

        // --- Validate SrUsds ---
        require(keccak256(abi.encodePacked(SrUsdsLike(instance.srUsds).version())) == keccak256(abi.encodePacked("1")), "SrUsdsInit/version-does-not-match");
        require(SrUsdsLike(instance.srUsds).getImplementation() == instance.srUsdsImp, "SrUsdsInit/imp-does-not-match");
        require(SrUsdsLike(instance.srUsds).usdsJoin() == dss.chainlog.getAddress("USDS_JOIN"), "SrUsdsInit/usdsJoin-does-not-match");
        require(SrUsdsLike(instance.srUsds).vow() == address(dss.vow), "SrUsdsInit/vow-does-not-match");
        require(SrUsdsLike(instance.srUsds).susds() == susds, "SrUsdsInit/susds-does-not-match");

        // --- Validate Queues ---
        require(QueuesLike(instance.queues).getImplementation() == instance.queuesImp, "SrUsdsInit/queues-imp-does-not-match");
        require(QueuesLike(instance.queues).share() == instance.srUsds, "SrUsdsInit/queues-share-does-not-match");
        require(QueuesLike(instance.queues).asset() == susds, "SrUsdsInit/queues-asset-does-not-match");

        // --- Validate Beam ---
        require(BeamLike(instance.beam).queues() == instance.queues, "SrUsdsInit/beam-queues-does-not-match");

        // --- Configure SrUsds ---
        // SrUsds generates USDS for gains through vat.suck
        dss.vat.rely(instance.srUsds);
        // The queues deposit, redeem and settle on SrUsds
        SrUsdsLike(instance.srUsds).rely(instance.queues);

        // --- Configure Queues ---
        QueuesLike(instance.queues).file("lockTimeEnd", cfg.lockTimeEnd); // Before lockTimeBgn, which must be less than it
        QueuesLike(instance.queues).file("lockTimeBgn", cfg.lockTimeBgn);
        QueuesLike(instance.queues).file("period",      cfg.period);
        QueuesLike(instance.queues).file("startDay",    cfg.startDay);
        QueuesLike(instance.queues).rely(instance.beam);

        // --- Configure Beam ---
        BeamLike(instance.beam).rely(instance.mom);
        BeamLike(instance.beam).file("maxMint",            cfg.maxMint);
        BeamLike(instance.beam).file("maxCut",             cfg.maxCut);
        BeamLike(instance.beam).file("maxDepositCapacity", cfg.maxDepositCapacity);
        BeamLike(instance.beam).file("maxRedeemCapacity",  cfg.maxRedeemCapacity);
        for (uint256 i; i < cfg.buds.length; i++) {
            BeamLike(instance.beam).kiss(cfg.buds[i]);
        }

        // --- Configure Mom ---
        MomLike(instance.mom).setAuthority(dss.chainlog.getAddress("MCD_ADM"));

        // --- Update Chainlog ---
        dss.chainlog.setAddress("SRUSDS",            instance.srUsds);
        dss.chainlog.setAddress("SRUSDS_IMP",        instance.srUsdsImp);
        dss.chainlog.setAddress("SRUSDS_QUEUES",     instance.queues);
        dss.chainlog.setAddress("SRUSDS_QUEUES_IMP", instance.queuesImp);
        dss.chainlog.setAddress("SRUSDS_BEAM",       instance.beam);
        dss.chainlog.setAddress("SRUSDS_MOM",        instance.mom);
    }
}
