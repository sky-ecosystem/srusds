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

import { SrUsds } from "src/srusds/SrUsds.sol";
import { SrUsdsHandler } from "src/srusds/SrUsdsHandler.sol";
import { LCTSBeam } from "src/LCTSBeam.sol";
import { LCTSMom } from "src/LCTSMom.sol";
import { LCTSDepositQueue } from "src/LCTSDepositQueue.sol";
import { LCTSWithdrawQueue } from "src/LCTSWithdrawQueue.sol";
import { SrUsdsInstance } from "./SrUsdsInstance.sol";

library SrUsdsDeploy {
    function deploy(
        address deployer,
        address owner
    ) internal returns (SrUsdsInstance memory instance) {
        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        address susds = chainlog.getAddress("SUSDS");

        // 1. Deploy SrUsds proxy
        address _srUsdsImp = address(new SrUsds(susds));
        address _srUsds = address(new ERC1967Proxy(_srUsdsImp, abi.encodeCall(SrUsds.initialize, ())));
        ScriptTools.switchOwner(_srUsds, deployer, owner);

        // 2. Deploy LCTS queues
        // DepositQueue: sUSDS -> srUSDS (underlying=susds, vault=srusds)
        address _depositQueue = address(new LCTSDepositQueue(susds, _srUsds));
        ScriptTools.switchOwner(_depositQueue, deployer, owner);

        // WithdrawQueue: srUSDS -> sUSDS (vault=srusds)
        address _withdrawQueue = address(new LCTSWithdrawQueue(_srUsds));
        ScriptTools.switchOwner(_withdrawQueue, deployer, owner);

        // 3. Deploy handler with queue addresses
        address _handler = address(new SrUsdsHandler(
            _srUsds,
            chainlog.getAddress("USDS_JOIN"),
            chainlog.getAddress("MCD_VOW"),
            _depositQueue,
            _withdrawQueue
        ));
        ScriptTools.switchOwner(_handler, deployer, owner);

        // 4. Deploy beam and mom
        address _beam = address(new LCTSBeam(_handler));
        ScriptTools.switchOwner(_beam, deployer, owner);

        LCTSMom _mom = new LCTSMom(_handler);
        _mom.setOwner(owner);

        instance.srUsds        = _srUsds;
        instance.srUsdsImp     = _srUsdsImp;
        instance.handler       = _handler;
        instance.beam           = _beam;
        instance.mom           = address(_mom);
        instance.depositQueue  = _depositQueue;
        instance.withdrawQueue = _withdrawQueue;
    }
}
