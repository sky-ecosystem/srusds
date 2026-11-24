// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

// SrUsdsQueues reduced to what SrUsdsBeam uses: the share getter, and a settle that only records how it was
// called. What the queues do with a settlement is verified in their own spec, so here the question is only
// whether the Beam forwards its arguments unchanged, and once. No authorization is modelled, the Beam being a
// ward of the real queues
contract QueuesMock {
    address public share;

    int256  public profit;
    uint256 public depositCapacity;
    uint256 public redeemCapacity;
    uint256 public settles;

    function settle(int256 profit_, uint256 depositCapacity_, uint256 redeemCapacity_) external {
        profit          = profit_;
        depositCapacity = depositCapacity_;
        redeemCapacity  = redeemCapacity_;
        settles++;
    }
}
