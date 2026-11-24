// SrUsdsBeam.spec
//
// The Beam checks a settlement against the facilitator's limits and forwards it to the queues. The queues are a
// mock that records how settle was called (what a settlement does is verified in the SrUsdsQueues spec). The
// share is the real SrUsds, of which the Beam only reads totalAssets()

using QueuesMock as queues;
using SrUsds as share;

methods {
    // storage variables
    function wards(address) external returns (uint256) envfree;
    function buds(address) external returns (uint256) envfree;
    function bad() external returns (uint8) envfree;
    function maxMint() external returns (uint256) envfree;
    function maxCut() external returns (uint256) envfree;
    function maxDepositCapacity() external returns (uint256) envfree;
    function maxRedeemCapacity() external returns (uint256) envfree;
    // immutables
    function queues() external returns (address) envfree;
    function share() external returns (address) envfree;
    //
    function queues.profit() external returns (int256) envfree;
    function queues.depositCapacity() external returns (uint256) envfree;
    function queues.redeemCapacity() external returns (uint256) envfree;
    function queues.settles() external returns (uint256) envfree;
    function share.totalSupply() external returns (uint256) envfree;
    function share.chi() external returns (uint192) envfree;
}

definition WAD() returns mathint = 10^18;
definition RAY() returns mathint = 10^27;
definition MIN_INT256() returns mathint = -2^255;

definition WHAT_BAD()                  returns bytes32 = to_bytes32(0x6261640000000000000000000000000000000000000000000000000000000000);
definition WHAT_MAX_MINT()             returns bytes32 = to_bytes32(0x6d61784d696e7400000000000000000000000000000000000000000000000000);
definition WHAT_MAX_CUT()              returns bytes32 = to_bytes32(0x6d61784375740000000000000000000000000000000000000000000000000000);
definition WHAT_MAX_DEPOSIT_CAPACITY() returns bytes32 = to_bytes32(0x6d61784465706f73697443617061636974790000000000000000000000000000);
definition WHAT_MAX_REDEEM_CAPACITY()  returns bytes32 = to_bytes32(0x6d617852656465656d4361706163697479000000000000000000000000000000);

// What the outstanding shares are worth, as SrUsds.totalAssets() computes it
definition defTotalAssets() returns mathint = share.totalSupply() * share.chi() / RAY();

invariant bad_LessOrEqual_one() bad() <= 1;
invariant maxMint_LessOrEqual_WAD() maxMint() <= WAD();
invariant maxCut_LessOrEqual_WAD() maxCut() <= WAD();

// Verify no more entry points exist
rule entryPoints(method f) filtered { f -> !f.isView } {
    env e;

    calldataarg args;
    f(e, args);

    assert f.selector == sig:rely(address).selector ||
           f.selector == sig:deny(address).selector ||
           f.selector == sig:kiss(address).selector ||
           f.selector == sig:diss(address).selector ||
           f.selector == sig:file(bytes32,uint256).selector ||
           f.selector == sig:settle(int256,uint256,uint256).selector;
}

// Verify that each storage layout is only modified in the corresponding functions
rule storageAffected(method f) {
    env e;

    address anyAddr;

    mathint wardsBefore = wards(anyAddr);
    mathint budsBefore = buds(anyAddr);
    mathint badBefore = bad();
    mathint maxMintBefore = maxMint();
    mathint maxCutBefore = maxCut();
    mathint maxDepositCapacityBefore = maxDepositCapacity();
    mathint maxRedeemCapacityBefore = maxRedeemCapacity();

    calldataarg args;
    f(e, args);

    mathint wardsAfter = wards(anyAddr);
    mathint budsAfter = buds(anyAddr);
    mathint badAfter = bad();
    mathint maxMintAfter = maxMint();
    mathint maxCutAfter = maxCut();
    mathint maxDepositCapacityAfter = maxDepositCapacity();
    mathint maxRedeemCapacityAfter = maxRedeemCapacity();

    assert wardsAfter != wardsBefore                           => f.selector == sig:rely(address).selector ||
                                                                  f.selector == sig:deny(address).selector;
    assert budsAfter != budsBefore                             => f.selector == sig:kiss(address).selector ||
                                                                  f.selector == sig:diss(address).selector;
    assert badAfter != badBefore                               => f.selector == sig:file(bytes32,uint256).selector;
    assert maxMintAfter != maxMintBefore                       => f.selector == sig:file(bytes32,uint256).selector;
    assert maxCutAfter != maxCutBefore                         => f.selector == sig:file(bytes32,uint256).selector;
    assert maxDepositCapacityAfter != maxDepositCapacityBefore => f.selector == sig:file(bytes32,uint256).selector;
    assert maxRedeemCapacityAfter != maxRedeemCapacityBefore   => f.selector == sig:file(bytes32,uint256).selector;
}

// Verify that only settle reaches the queues
rule queuesAffected(method f) {
    env e;

    mathint settlesBefore = queues.settles();

    calldataarg args;
    f(e, args);

    mathint settlesAfter = queues.settles();

    assert settlesAfter != settlesBefore => f.selector == sig:settle(int256,uint256,uint256).selector;
}

// Verify correct storage changes for non reverting rely
rule rely(address usr) {
    env e;

    address otherAddr;
    require otherAddr != usr;

    mathint wardsOtherBefore = wards(otherAddr);

    rely(e, usr);

    mathint wardsUsrAfter = wards(usr);
    mathint wardsOtherAfter = wards(otherAddr);

    assert wardsUsrAfter == 1;
    assert wardsOtherAfter == wardsOtherBefore;
}

// Verify revert rules on rely
rule rely_revert(address usr) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    rely@withrevert(e, usr);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct storage changes for non reverting deny
rule deny(address usr) {
    env e;

    address otherAddr;
    require otherAddr != usr;

    mathint wardsOtherBefore = wards(otherAddr);

    deny(e, usr);

    mathint wardsUsrAfter = wards(usr);
    mathint wardsOtherAfter = wards(otherAddr);

    assert wardsUsrAfter == 0;
    assert wardsOtherAfter == wardsOtherBefore;
}

// Verify revert rules on deny
rule deny_revert(address usr) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    deny@withrevert(e, usr);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct storage changes for non reverting kiss
rule kiss(address usr) {
    env e;

    address otherAddr;
    require otherAddr != usr;

    mathint budsOtherBefore = buds(otherAddr);

    kiss(e, usr);

    mathint budsUsrAfter = buds(usr);
    mathint budsOtherAfter = buds(otherAddr);

    assert budsUsrAfter == 1;
    assert budsOtherAfter == budsOtherBefore;
}

// Verify revert rules on kiss
rule kiss_revert(address usr) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    kiss@withrevert(e, usr);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct storage changes for non reverting diss
rule diss(address usr) {
    env e;

    address otherAddr;
    require otherAddr != usr;

    mathint budsOtherBefore = buds(otherAddr);

    diss(e, usr);

    mathint budsUsrAfter = buds(usr);
    mathint budsOtherAfter = buds(otherAddr);

    assert budsUsrAfter == 0;
    assert budsOtherAfter == budsOtherBefore;
}

// Verify revert rules on diss
rule diss_revert(address usr) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    diss@withrevert(e, usr);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct storage changes for non reverting file
rule file(bytes32 what, uint256 data) {
    env e;

    mathint badBefore = bad();
    mathint maxMintBefore = maxMint();
    mathint maxCutBefore = maxCut();
    mathint maxDepositCapacityBefore = maxDepositCapacity();
    mathint maxRedeemCapacityBefore = maxRedeemCapacity();

    file(e, what, data);

    mathint badAfter = bad();
    mathint maxMintAfter = maxMint();
    mathint maxCutAfter = maxCut();
    mathint maxDepositCapacityAfter = maxDepositCapacity();
    mathint maxRedeemCapacityAfter = maxRedeemCapacity();

    assert what == WHAT_BAD()                  => badAfter == to_mathint(data);
    assert what != WHAT_BAD()                  => badAfter == badBefore;
    assert what == WHAT_MAX_MINT()             => maxMintAfter == to_mathint(data);
    assert what != WHAT_MAX_MINT()             => maxMintAfter == maxMintBefore;
    assert what == WHAT_MAX_CUT()              => maxCutAfter == to_mathint(data);
    assert what != WHAT_MAX_CUT()              => maxCutAfter == maxCutBefore;
    assert what == WHAT_MAX_DEPOSIT_CAPACITY() => maxDepositCapacityAfter == to_mathint(data);
    assert what != WHAT_MAX_DEPOSIT_CAPACITY() => maxDepositCapacityAfter == maxDepositCapacityBefore;
    assert what == WHAT_MAX_REDEEM_CAPACITY()  => maxRedeemCapacityAfter == to_mathint(data);
    assert what != WHAT_MAX_REDEEM_CAPACITY()  => maxRedeemCapacityAfter == maxRedeemCapacityBefore;
}

// Verify revert rules on file
rule file_revert(bytes32 what, uint256 data) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    file@withrevert(e, what, data);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;
    bool revert3 = what != WHAT_BAD() && what != WHAT_MAX_MINT() && what != WHAT_MAX_CUT() &&
                   what != WHAT_MAX_DEPOSIT_CAPACITY() && what != WHAT_MAX_REDEEM_CAPACITY();
    bool revert4 = what == WHAT_BAD() && data != 0 && data != 1;
    bool revert5 = what == WHAT_MAX_MINT() && data > WAD();
    bool revert6 = what == WHAT_MAX_CUT() && data > WAD();

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6;
}

// Verify correct storage changes for non reverting settle
rule settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) {
    env e;

    requireInvariant maxMint_LessOrEqual_WAD();
    requireInvariant maxCut_LessOrEqual_WAD();

    mathint settlesBefore = queues.settles();

    settle(e, profit, depositCapacity, redeemCapacity);

    mathint queuesProfitAfter = queues.profit();
    mathint queuesDepositCapacityAfter = queues.depositCapacity();
    mathint queuesRedeemCapacityAfter = queues.redeemCapacity();
    mathint settlesAfter = queues.settles();

    // The queues are settled once, with the same arguments
    assert queuesProfitAfter == to_mathint(profit);
    assert queuesDepositCapacityAfter == to_mathint(depositCapacity);
    assert queuesRedeemCapacityAfter == to_mathint(redeemCapacity);
    assert settlesAfter == settlesBefore + 1;
}

// Verify revert rules on settle
rule settle_revert(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) {
    env e;

    require share.totalSupply() * share.chi() <= max_uint256;
    require queues.settles() < max_uint256;

    mathint budsSender = buds(e.msg.sender);
    mathint bad = bad();
    mathint maxMint = maxMint();
    mathint maxCut = maxCut();
    mathint maxDepositCapacity = maxDepositCapacity();
    mathint maxRedeemCapacity = maxRedeemCapacity();

    mathint totalAssets = defTotalAssets();

    settle@withrevert(e, profit, depositCapacity, redeemCapacity);

    bool revert1  = e.msg.value > 0;
    bool revert2  = budsSender != 1;
    bool revert3  = bad != 0;
    bool revert4  = profit > 0 && totalAssets * maxMint > max_uint256;
    bool revert5  = profit > 0 && profit > totalAssets * maxMint / WAD();
    bool revert6  = to_mathint(profit) == MIN_INT256();
    bool revert7  = profit < 0 && totalAssets * maxCut > max_uint256;
    bool revert8  = profit < 0 && -profit > totalAssets * maxCut / WAD();
    bool revert9  = profit < 0 && depositCapacity != 0;
    bool revert10 = to_mathint(depositCapacity) > maxDepositCapacity;
    bool revert11 = to_mathint(redeemCapacity) > maxRedeemCapacity;

    assert lastReverted <=> revert1  || revert2  || revert3  ||
                            revert4  || revert5  || revert6  ||
                            revert7  || revert8  || revert9  ||
                            revert10 || revert11;
}
