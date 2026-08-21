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

import { Venture } from "src/Venture.sol";
import { VentureHandler } from "src/VentureHandler.sol";
import { VentureBeam } from "src/VentureBeam.sol";
import { VentureMom } from "src/VentureMom.sol";
import { VentureInstance } from "./VentureInstance.sol";

library VentureDeploy {
    function deploy(
        address deployer,
        address owner
    ) internal returns (VentureInstance memory instance) {
        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        address susds = chainlog.getAddress("SUSDS");

        // 1. Deploy Venture proxy
        address _ventureImp = address(new Venture());
        address _venture = address(new ERC1967Proxy(_ventureImp, abi.encodeCall(Venture.initialize, ())));
        ScriptTools.switchOwner(_venture, deployer, owner);

        // 2. Deploy handler, which holds both queues
        address _handler = address(new VentureHandler(susds, _venture));
        ScriptTools.switchOwner(_handler, deployer, owner);

        // 3. Deploy beam and mom
        address _beam = address(new VentureBeam(_handler));
        ScriptTools.switchOwner(_beam, deployer, owner);

        VentureMom _mom = new VentureMom(_handler);
        _mom.setOwner(owner);

        instance.venture    = _venture;
        instance.ventureImp = _ventureImp;
        instance.handler  = _handler;
        instance.beam     = _beam;
        instance.mom      = address(_mom);
    }
}
