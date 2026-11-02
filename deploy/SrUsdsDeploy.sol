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

import { ScriptTools } from "dss-test/ScriptTools.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "dss-interfaces/Interfaces.sol";

import { SrUsds } from "src/SrUsds.sol";
import { SrUsdsQueues } from "src/SrUsdsQueues.sol";
import { SrUsdsBeam } from "src/SrUsdsBeam.sol";
import { SrUsdsMom } from "src/SrUsdsMom.sol";
import { SrUsdsInstance } from "./SrUsdsInstance.sol";

library SrUsdsDeploy {
    function deploy(
        address deployer,
        address owner
    ) internal returns (SrUsdsInstance memory instance) {
        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        // 1. Deploy the SrUsds token behind a proxy
        address _srUsdsImp = address(new SrUsds(chainlog.getAddress("USDS_JOIN"), chainlog.getAddress("MCD_VOW"), chainlog.getAddress("SUSDS")));
        address _srUsds = address(new ERC1967Proxy(_srUsdsImp, abi.encodeCall(SrUsds.initialize, ())));
        ScriptTools.switchOwner(_srUsds, deployer, owner);

        // 2. Deploy the queues behind a proxy
        address _queuesImp = address(new SrUsdsQueues(_srUsds));
        address _queues = address(new ERC1967Proxy(_queuesImp, abi.encodeCall(SrUsdsQueues.initialize, ())));
        ScriptTools.switchOwner(_queues, deployer, owner);

        // 3. Deploy the beam and the mom
        address _beam = address(new SrUsdsBeam(_queues));
        ScriptTools.switchOwner(_beam, deployer, owner);

        SrUsdsMom _mom = new SrUsdsMom();
        _mom.setOwner(owner);

        instance.srUsds    = _srUsds;
        instance.srUsdsImp = _srUsdsImp;
        instance.queues    = _queues;
        instance.queuesImp = _queuesImp;
        instance.beam      = _beam;
        instance.mom       = address(_mom);
    }
}
