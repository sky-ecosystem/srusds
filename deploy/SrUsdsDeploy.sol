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
import { SrUsdsHandler } from "src/SrUsdsHandler.sol";
import { SrUsdsSettler } from "src/SrUsdsSettler.sol";
import { SrUsdsMom } from "src/SrUsdsMom.sol";
import { SrUsdsInstance } from "./SrUsdsInstance.sol";

interface SPBEAMLike {
    function conv() external view returns (address);
}

library SrUsdsDeploy {
    function deploy(
        address deployer,
        address owner
    ) internal returns (SrUsdsInstance memory instance) {
        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        address _srUsdsImp = address(new SrUsds(
                                            chainlog.getAddress("SUSDS")
                                        )
                                    );
        address _srUsds = address(new ERC1967Proxy(_srUsdsImp, abi.encodeCall(SrUsds.initialize, ())));
        ScriptTools.switchOwner(_srUsds, deployer, owner);

        address _handler = address(new SrUsdsHandler(_srUsds, chainlog.getAddress("USDS_JOIN"), chainlog.getAddress("MCD_VOW")));
        ScriptTools.switchOwner(_handler, deployer, owner);

        address _settler = address(new SrUsdsSettler(
            _handler
        ));
        ScriptTools.switchOwner(_settler, deployer, owner);

        SrUsdsMom _mom = new SrUsdsMom(_handler);
        _mom.setOwner(owner);

        instance.srUsds    = _srUsds;
        instance.srUsdsImp = _srUsdsImp;
        instance.handler   = _handler;
        instance.settler   = _settler;
        instance.mom       = address(_mom);
    }
}
