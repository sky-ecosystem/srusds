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

struct SettlerConfig {
    uint256   zzz;
    uint256   maxMint;
    uint256   maxCut;
    address[] buds;
}

library SrUsdsInit {

    uint256 constant internal RAY                   = 10**27;
    uint256 constant internal RATES_ONE_HUNDRED_PCT = 1000000021979553151239153027;

    function init(
        DssInstance    memory dss,
        SrUsdsInstance memory instance,
        SettlerConfig  memory cfg
    ) internal {
        require(keccak256(abi.encodePacked(SrUsdsLike(instance.srUsds).version())) == keccak256(abi.encodePacked("1")), "SrUsdsInit/version-does-not-match");
        require(SrUsdsLike(instance.srUsds).getImplementation() == instance.srUsdsImp, "SrUsdsInit/imp-does-not-match");

        require(SrUsdsLike(instance.srUsds).susds() == dss.chainlog.getAddress("SUSDS"), "SrUsdsInit/susds-does-not-match");

        require(HandlerLike(instance.handler).srusds() == instance.srUsds, "SrUsdsInit/usdsJoin-does-not-match");
        require(HandlerLike(instance.handler).usdsJoin() == dss.chainlog.getAddress("USDS_JOIN"), "SrUsdsInit/usdsJoin-does-not-match");
        require(HandlerLike(instance.handler).vow() == address(dss.vow), "SrUsdsInit/vow-does-not-match");

        require(SettlerLike(instance.settler).handler() == instance.handler, "SrUsdsInit/handler-does-not-match");

        require(SrUsdsMomLike(instance.mom).handler() == instance.handler, "SrUsdsInit/handler-does-not-match");

        dss.vat.rely(instance.handler);

        SrUsdsLike(instance.srUsds).rely(instance.handler);
        SrUsdsLike(instance.srUsds).rely(instance.mom);

        HandlerLike(instance.handler).rely(instance.settler);

        SettlerLike(instance.settler).rely(instance.mom);
        SettlerLike(instance.settler).file("zzz", cfg.zzz);
        SettlerLike(instance.settler).file("maxMint", cfg.maxMint);
        SettlerLike(instance.settler).file("maxCut", cfg.maxCut);

        for (uint256 i; i < cfg.buds.length; i ++) {
            SettlerLike(instance.settler).kiss(cfg.buds[i]);
        }

        SrUsdsMomLike(instance.mom).setAuthority(dss.chainlog.getAddress("MCD_ADM"));

        dss.chainlog.setAddress("SRUSDS",         instance.srUsds);
        dss.chainlog.setAddress("SRUSDS_IMP",     instance.srUsdsImp);
        dss.chainlog.setAddress("SRUSDS_SETTLER", instance.settler);
        dss.chainlog.setAddress("SRUSDS_MOM",     instance.mom);
    }
}
