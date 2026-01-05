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
    function susds() external view returns (address);
    function rely(address) external;
}

interface HandlerLike {
    function srusds() external view returns (address);
    function usdsJoin() external view returns (address);
    function vow() external view returns (address);
    function depositQueue() external view returns (address);
    function withdrawQueue() external view returns (address);
    function file(bytes32, uint256) external;
    function rely(address) external;
}

interface SettlerLike {
    function handler() external view returns (address);
    function file(bytes32, uint256) external;
    function kiss(address) external;
    function rely(address) external;
}

interface SrUsdsMomLike {
    function handler() external view returns (address);
    function setAuthority(address) external;
}

interface LCTSQueueLike {
    function underlying() external view returns (address);
    function vault() external view returns (address);
    function asset() external view returns (address);
    function rely(address) external;
}

struct SrUsdsConfig {
    uint256   handlerHop;
    uint256   settlerZzz;
    uint256   settlerMaxMint;
    uint256   settlerMaxCut;
    uint256   settlerMaxDepositCapacity;
    uint256   settlerMaxWithdrawCapacity;
    address[] settlerBuds;
}

library SrUsdsInit {

    uint256 constant internal RAY = 10**27;

    function init(
        DssInstance    memory dss,
        SrUsdsInstance memory instance,
        SrUsdsConfig   memory cfg
    ) internal {
        // --- Validate SrUsds ---
        require(keccak256(abi.encodePacked(SrUsdsLike(instance.srUsds).version())) == keccak256(abi.encodePacked("1")), "SrUsdsInit/version-does-not-match");
        require(SrUsdsLike(instance.srUsds).getImplementation() == instance.srUsdsImp, "SrUsdsInit/imp-does-not-match");
        require(SrUsdsLike(instance.srUsds).susds() == dss.chainlog.getAddress("SUSDS"), "SrUsdsInit/susds-does-not-match");

        // --- Validate Handler ---
        require(HandlerLike(instance.handler).srusds() == instance.srUsds, "SrUsdsInit/handler-srusds-mismatch");
        require(HandlerLike(instance.handler).usdsJoin() == dss.chainlog.getAddress("USDS_JOIN"), "SrUsdsInit/usdsJoin-does-not-match");
        require(HandlerLike(instance.handler).vow() == address(dss.vow), "SrUsdsInit/vow-does-not-match");
        require(HandlerLike(instance.handler).depositQueue() == instance.depositQueue, "SrUsdsInit/depositQueue-mismatch");
        require(HandlerLike(instance.handler).withdrawQueue() == instance.withdrawQueue, "SrUsdsInit/withdrawQueue-mismatch");

        // --- Validate Settler ---
        require(SettlerLike(instance.settler).handler() == instance.handler, "SrUsdsInit/settler-handler-mismatch");

        // --- Validate Mom ---
        require(SrUsdsMomLike(instance.mom).handler() == instance.handler, "SrUsdsInit/mom-handler-mismatch");

        // --- Validate DepositQueue ---
        require(LCTSQueueLike(instance.depositQueue).underlying() == dss.chainlog.getAddress("SUSDS"), "SrUsdsInit/depositQueue-underlying-mismatch");
        require(LCTSQueueLike(instance.depositQueue).vault() == instance.srUsds, "SrUsdsInit/depositQueue-vault-mismatch");

        // --- Validate WithdrawQueue ---
        require(LCTSQueueLike(instance.withdrawQueue).vault() == instance.srUsds, "SrUsdsInit/withdrawQueue-vault-mismatch");
        require(LCTSQueueLike(instance.withdrawQueue).asset() == dss.chainlog.getAddress("SUSDS"), "SrUsdsInit/withdrawQueue-asset-mismatch");

        // --- Configure VAT permissions ---
        dss.vat.rely(instance.handler);

        // --- Configure SrUsds permissions ---
        // Handler needs auth to call settle()
        SrUsdsLike(instance.srUsds).rely(instance.handler);
        // Mom needs auth for emergency actions
        SrUsdsLike(instance.srUsds).rely(instance.mom);
        // DepositQueue needs auth to call deposit() on SrUsds
        SrUsdsLike(instance.srUsds).rely(instance.depositQueue);
        // WithdrawQueue needs auth to call redeem() on SrUsds
        SrUsdsLike(instance.srUsds).rely(instance.withdrawQueue);

        // --- Configure Handler ---
        HandlerLike(instance.handler).file("hop", cfg.handlerHop);
        HandlerLike(instance.handler).rely(instance.settler);
        HandlerLike(instance.handler).rely(instance.mom);

        // --- Configure Queues ---
        // Handler needs auth to call settle() on queues
        LCTSQueueLike(instance.depositQueue).rely(instance.handler);
        LCTSQueueLike(instance.withdrawQueue).rely(instance.handler);

        // --- Configure Settler ---
        SettlerLike(instance.settler).rely(instance.mom);
        SettlerLike(instance.settler).file("zzz", cfg.settlerZzz);
        SettlerLike(instance.settler).file("maxMint", cfg.settlerMaxMint);
        SettlerLike(instance.settler).file("maxCut", cfg.settlerMaxCut);
        SettlerLike(instance.settler).file("maxDepositCapacity", cfg.settlerMaxDepositCapacity);
        SettlerLike(instance.settler).file("maxWithdrawCapacity", cfg.settlerMaxWithdrawCapacity);

        for (uint256 i; i < cfg.settlerBuds.length; i++) {
            SettlerLike(instance.settler).kiss(cfg.settlerBuds[i]);
        }

        // --- Configure Mom ---
        SrUsdsMomLike(instance.mom).setAuthority(dss.chainlog.getAddress("MCD_ADM"));

        // --- Update Chainlog ---
        dss.chainlog.setAddress("SRUSDS",              instance.srUsds);
        dss.chainlog.setAddress("SRUSDS_IMP",          instance.srUsdsImp);
        dss.chainlog.setAddress("SRUSDS_HANDLER",      instance.handler);
        dss.chainlog.setAddress("SRUSDS_SETTLER",      instance.settler);
        dss.chainlog.setAddress("SRUSDS_MOM",          instance.mom);
        dss.chainlog.setAddress("SRUSDS_DEPOSIT_QUEUE",  instance.depositQueue);
        dss.chainlog.setAddress("SRUSDS_WITHDRAW_QUEUE", instance.withdrawQueue);
    }
}
