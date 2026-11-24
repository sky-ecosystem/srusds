// SrUsdsQueues.spec
//
// The two queues run the same internal logic (_sync, _queue, _cancel, _claim, _convert) over different storage
// and tokens. The spec mirrors that: every accessor and expected value takes `dep`, true for the deposit queue
// and false for the redeem queue, and each pair of external functions is checked by one shared CVL function.
//
//                  | underlying (queued, cancelled) | converted (claimed)
//   deposit queue  | asset (sUSDS)                  | share (srUSDS)
//   redeem queue   | share (srUSDS)                 | asset (sUSDS)

using ShareMock as share;
using SUsdsMock as asset;

methods {
    // storage variables
    function wards(address) external returns (uint256) envfree;
    function lockTimeBgn() external returns (uint32) envfree;
    function lockTimeEnd() external returns (uint32) envfree;
    function period() external returns (uint32) envfree;
    function startDay() external returns (uint32) envfree;
    function lastSettleDay() external returns (uint32) envfree;
    function isOperator(address, address) external returns (bool) envfree;
    // immutables
    function share() external returns (address) envfree;
    function asset() external returns (address) envfree;
    // views
    function isQueueDepositClosed() external returns (bool) envfree;
    function isQueueRedeemClosed() external returns (bool) envfree;
    function pendingDeposit(address) external returns (uint256) envfree;
    function pendingRedeem(address) external returns (uint256) envfree;
    function claimableDeposit(address) external returns (uint256) envfree;
    function claimableRedeem(address) external returns (uint256) envfree;
    //
    function share.balanceOf(address) external returns (uint256) envfree;
    function share.allowance(address, address) external returns (uint256) envfree;
    function share.totalSupply() external returns (uint256) envfree;
    function share.chi() external returns (uint256) envfree;
    function share.chiAfterSettle() external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function asset.allowance(address, address) external returns (uint256) envfree;
    function asset.totalSupply() external returns (uint256) envfree;
}

definition RAY() returns mathint = 10^27;
definition DAY() returns mathint = 86400;
definition MAX_UNIT_RATIO() returns mathint = 10^9;
definition _min(mathint x, mathint y) returns mathint = x < y ? x : y;

// --- Storage accessors (direct storage access) ---

definition qGen(bool dep) returns uint256 =
    dep ? currentContract.depositQueue.gen : currentContract.redeemQueue.gen;
definition qTotalUnits(bool dep) returns uint256 =
    dep ? currentContract.depositQueue.totalUnits : currentContract.redeemQueue.totalUnits;
definition qPending(bool dep) returns uint256 =
    dep ? currentContract.depositQueue.pendingUnderlying : currentContract.redeemQueue.pendingUnderlying;
definition qConvertedPerUnit(bool dep, uint256 gen) returns uint256 =
    dep ? currentContract.depositQueue.convertedPerUnit[gen] : currentContract.redeemQueue.convertedPerUnit[gen];

definition posGen(bool dep, address usr) returns uint256 =
    dep ? currentContract.depositQueue.positions[usr].gen : currentContract.redeemQueue.positions[usr].gen;
definition posUnits(bool dep, address usr) returns uint256 =
    dep ? currentContract.depositQueue.positions[usr].units : currentContract.redeemQueue.positions[usr].units;
definition posLast(bool dep, address usr) returns uint256 =
    dep ? currentContract.depositQueue.positions[usr].lastConvertedPerUnit : currentContract.redeemQueue.positions[usr].lastConvertedPerUnit;
definition posClaimable(bool dep, address usr) returns uint256 =
    dep ? currentContract.depositQueue.positions[usr].claimable : currentContract.redeemQueue.positions[usr].claimable;

// --- Tokens ---

// What a queue takes on a request and returns on a cancel
definition underlyingToken(bool dep) returns address = dep ? asset() : share();
definition underlyingBalanceOf(bool dep, address usr) returns uint256 = dep ? asset.balanceOf(usr) : share.balanceOf(usr);
definition underlyingAllowance(bool dep, address owner, address spender) returns uint256 = dep ? asset.allowance(owner, spender) : share.allowance(owner, spender);
definition underlyingTotalSupply(bool dep) returns uint256 = dep ? asset.totalSupply() : share.totalSupply();

// What a queue pays on a claim
definition convertedToken(bool dep) returns address = dep ? share() : asset();
definition convertedBalanceOf(bool dep, address usr) returns uint256 = dep ? share.balanceOf(usr) : asset.balanceOf(usr);
definition convertedTotalSupply(bool dep) returns uint256 = dep ? share.totalSupply() : asset.totalSupply();

// --- Authorization ---

// _checkOperator(usr)
definition isAllowed(address usr, address sender) returns bool = usr == sender || isOperator(usr, sender);

// --- Lock: _locked() ---

definition dayOf(env e) returns mathint = e.block.timestamp / DAY();
definition timeOf(env e) returns mathint = e.block.timestamp % DAY();

// The modulo by a period of 0 panics, once the schedule has started
definition lockedReverts(env e) returns bool = dayOf(e) >= startDay() && period() == 0;

definition isLocked(env e) returns bool =
    dayOf(e) >= startDay() &&
    period() != 0 && (dayOf(e) - startDay()) % period() == 0 &&
    timeOf(e) >= lockTimeBgn() &&
    timeOf(e) < lockTimeEnd() &&
    lastSettleDay() < dayOf(e);

// --- Closed generation: _closed(queue) ---

definition closedReverts(bool dep) returns bool = qPending(dep) * MAX_UNIT_RATIO() > max_uint256;
definition isClosed(bool dep) returns bool = qTotalUnits(dep) > qPending(dep) * MAX_UNIT_RATIO();

// --- Position sync: _sync(queue, pos) ---

// What converted per unit in the position's generation since its last sync
definition syncDelta(bool dep, address usr) returns mathint = qConvertedPerUnit(dep, posGen(dep, usr)) - posLast(dep, usr);
// The position's generation was fully converted
definition syncStale(bool dep, address usr) returns bool = posGen(dep, usr) < qGen(dep);

// The position after a sync
definition syncClaimable(bool dep, address usr) returns mathint = posClaimable(dep, usr) + posUnits(dep, usr) * syncDelta(dep, usr) / RAY();
definition syncGen(bool dep, address usr) returns mathint = syncStale(dep, usr) ? qGen(dep) : posGen(dep, usr);
definition syncUnits(bool dep, address usr) returns mathint = syncStale(dep, usr) ? 0 : posUnits(dep, usr);
definition syncLast(bool dep, address usr) returns mathint = syncStale(dep, usr) ? qConvertedPerUnit(dep, qGen(dep)) : qConvertedPerUnit(dep, posGen(dep, usr));

definition syncReverts(bool dep, address usr) returns bool =
    syncDelta(dep, usr) < 0 ||
    posUnits(dep, usr) * syncDelta(dep, usr) > max_uint256 ||
    syncClaimable(dep, usr) > max_uint256;

// --- Views: _pending(queue, controller) ---

// With units pending in a queue that has none in total the division panics, so the value is not used there
definition pendingCalc(bool dep, address usr) returns mathint =
    (posUnits(dep, usr) == 0 || posGen(dep, usr) < qGen(dep) || qTotalUnits(dep) == 0) ? 0 : posUnits(dep, usr) * qPending(dep) / qTotalUnits(dep);

// --- Ghosts: what the queues owe ---

// Units held by the positions of each generation of a queue: sumUnits[dep][gen]
ghost mapping(bool => mapping(uint256 => mathint)) sumUnits {
    init_state axiom forall bool dep. forall uint256 gen. sumUnits[dep][gen] == 0;
}

// What the positions of a queue can claim, summed over all of them and in ray, before each one is rounded down
// to its claimable amount: the sum of posOwedRay
ghost mapping(bool => mathint) owedRay {
    init_state axiom forall bool dep. owedRay[dep] == 0;
}

// What one position can claim, in ray: at least its claimable view times RAY, which rounds the second term down
definition posOwedRay(bool dep, address usr) returns mathint = posClaimable(dep, usr) * RAY() + posUnits(dep, usr) * syncDelta(dep, usr);

// The ghosts follow every store to a position field or to an accumulator. Each one changes a single field, so the
// others are read as they are at that moment (a store hook runs before the write)
function onClaimableStore(bool dep, uint256 claimable, uint256 oldClaimable) {
    owedRay[dep] = owedRay[dep] + (claimable - oldClaimable) * RAY();
}

function onUnitsStore(bool dep, address usr, uint256 units, uint256 oldUnits) {
    uint256 gen = posGen(dep, usr);
    sumUnits[dep][gen] = sumUnits[dep][gen] + units - oldUnits;
    owedRay[dep] = owedRay[dep] + (units - oldUnits) * syncDelta(dep, usr);
}

function onGenStore(bool dep, address usr, uint256 gen, uint256 oldGen) {
    mathint units = posUnits(dep, usr);
    sumUnits[dep][oldGen] = sumUnits[dep][oldGen] - units;
    sumUnits[dep][gen] = sumUnits[dep][gen] + units;
    owedRay[dep] = owedRay[dep] + units * (qConvertedPerUnit(dep, gen) - qConvertedPerUnit(dep, oldGen));
}

function onLastStore(bool dep, address usr, uint256 last, uint256 oldLast) {
    owedRay[dep] = owedRay[dep] - posUnits(dep, usr) * (last - oldLast);
}

function onConvertedPerUnitStore(bool dep, uint256 gen, uint256 convertedPerUnit, uint256 oldConvertedPerUnit) {
    owedRay[dep] = owedRay[dep] + sumUnits[dep][gen] * (convertedPerUnit - oldConvertedPerUnit);
}

hook Sstore currentContract.depositQueue.positions[KEY address usr].claimable uint256 claimable (uint256 oldClaimable) {
    onClaimableStore(true, claimable, oldClaimable);
}
hook Sstore currentContract.depositQueue.positions[KEY address usr].units uint256 units (uint256 oldUnits) {
    onUnitsStore(true, usr, units, oldUnits);
}
hook Sstore currentContract.depositQueue.positions[KEY address usr].gen uint256 gen (uint256 oldGen) {
    onGenStore(true, usr, gen, oldGen);
}
hook Sstore currentContract.depositQueue.positions[KEY address usr].lastConvertedPerUnit uint256 last (uint256 oldLast) {
    onLastStore(true, usr, last, oldLast);
}
hook Sstore currentContract.depositQueue.convertedPerUnit[KEY uint256 gen] uint256 convertedPerUnit (uint256 oldConvertedPerUnit) {
    onConvertedPerUnitStore(true, gen, convertedPerUnit, oldConvertedPerUnit);
}

hook Sstore currentContract.redeemQueue.positions[KEY address usr].claimable uint256 claimable (uint256 oldClaimable) {
    onClaimableStore(false, claimable, oldClaimable);
}
hook Sstore currentContract.redeemQueue.positions[KEY address usr].units uint256 units (uint256 oldUnits) {
    onUnitsStore(false, usr, units, oldUnits);
}
hook Sstore currentContract.redeemQueue.positions[KEY address usr].gen uint256 gen (uint256 oldGen) {
    onGenStore(false, usr, gen, oldGen);
}
hook Sstore currentContract.redeemQueue.positions[KEY address usr].lastConvertedPerUnit uint256 last (uint256 oldLast) {
    onLastStore(false, usr, last, oldLast);
}
hook Sstore currentContract.redeemQueue.convertedPerUnit[KEY uint256 gen] uint256 convertedPerUnit (uint256 oldConvertedPerUnit) {
    onConvertedPerUnitStore(false, gen, convertedPerUnit, oldConvertedPerUnit);
}

// --- Invariants ---

// A queue has no units exactly when it has nothing pending: the last position to cancel holds every unit, so it
// is returned everything pending, and a conversion that takes everything pending clears the units
invariant unitsZeroIffPendingZero(bool dep)
    qTotalUnits(dep) == 0 <=> qPending(dep) == 0
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    }

// The units per unit of underlying never go below 1: units are minted at 1:1 or above, a cancel removes at most
// the underlying its units stand for, and a conversion only lowers the underlying
invariant totalUnitsCoverPending(bool dep)
    qTotalUnits(dep) >= qPending(dep)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    } {
        preserved {
            // A request into a queue with no units is minted 1:1, which needs nothing to be pending
            requireInvariant unitsZeroIffPendingZero(dep);
        }
    }

// A position is never in a generation the queue has not reached
invariant positionGenNotAhead(bool dep, address usr)
    posGen(dep, usr) <= qGen(dep)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    }

// A position was last synced at a value its generation's accumulator has reached, so a sync never underflows
invariant positionLastWithinConvertedPerUnit(bool dep, address usr)
    posLast(dep, usr) <= qConvertedPerUnit(dep, posGen(dep, usr))
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    }

// The queues contract approves no operator, so nobody can queue its own balances
invariant queuesHasNoOperator(address usr)
    !isOperator(currentContract, usr)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    } {
        preserved with (env e) {
            require e.msg.sender != currentContract;
        }
    }

// No position holds units in a generation the queue has not reached
invariant noUnitsInFutureGeneration(bool dep, uint256 gen)
    gen > qGen(dep) => sumUnits[dep][gen] == 0
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    } {
        preserved queueDeposit(uint256 assets, address controller, address owner, uint16 referral) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved queueRedeem(uint256 shares, address controller, address owner) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved cancelDeposit(address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved cancelRedeem(address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved claimDeposit(uint256 shares, address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved claimRedeem(uint256 assets, address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
    }

// The units of the positions in the queue's current generation add up to its totalUnits
invariant liveUnitsSumToTotalUnits(bool dep)
    sumUnits[dep][qGen(dep)] == to_mathint(qTotalUnits(dep))
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    } {
        preserved queueDeposit(uint256 assets, address controller, address owner, uint16 referral) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved queueRedeem(uint256 shares, address controller, address owner) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved cancelDeposit(address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved cancelRedeem(address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved claimDeposit(uint256 shares, address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved claimRedeem(uint256 assets, address receiver, address controller) with (env e) {
            requireInvariant positionGenNotAhead(dep, controller);
        }
        preserved settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) with (env e) {
            // A drained queue moves to the next generation, which has no units yet
            requireInvariant noUnitsInFutureGeneration(dep, require_uint256(qGen(dep) + 1));
        }
    }

// The queues hold the sUSDS they owe: what is pending in the deposit queue plus what the redeem queue's positions
// can claim. In ray, so it holds before each position's claimable amount is rounded down
invariant queuesHoldAssetsOwed()
    asset.balanceOf(currentContract) * RAY() >= qPending(true) * RAY() + owedRay[false]
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    } {
        preserved with (env e) {
            // The queues contract is never an owner: it does not call itself and approves no operator
            require e.msg.sender != currentContract;
            requireInvariant queuesHasNoOperator(e.msg.sender);
            // A conversion credits the units of the current generation with at most what it received
            requireInvariant liveUnitsSumToTotalUnits(false);
        }
    }

// The queues hold the srUSDS they owe: what is pending in the redeem queue plus what the deposit queue's
// positions can claim
invariant queuesHoldSharesOwed()
    share.balanceOf(currentContract) * RAY() >= qPending(false) * RAY() + owedRay[true]
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
    } {
        preserved with (env e) {
            // The queues contract is never an owner: it does not call itself and approves no operator
            require e.msg.sender != currentContract;
            requireInvariant queuesHasNoOperator(e.msg.sender);
            // A conversion credits the units of the current generation with at most what it received
            requireInvariant liveUnitsSumToTotalUnits(true);
        }
    }

// --- Entry points and storage ---

rule entryPoints(method f) filtered { f -> !f.isView } {
    env e;

    calldataarg args;
    f(e, args);

    assert f.selector == sig:initialize().selector ||
           f.selector == sig:upgradeToAndCall(address,bytes).selector ||
           f.selector == sig:rely(address).selector ||
           f.selector == sig:deny(address).selector ||
           f.selector == sig:file(bytes32,uint256).selector ||
           f.selector == sig:settle(int256,uint256,uint256).selector ||
           f.selector == sig:setOperator(address,bool).selector ||
           f.selector == sig:queueDeposit(uint256,address,address,uint16).selector ||
           f.selector == sig:queueRedeem(uint256,address,address).selector ||
           f.selector == sig:cancelDeposit(address,address).selector ||
           f.selector == sig:cancelRedeem(address,address).selector ||
           f.selector == sig:claimDeposit(uint256,address,address).selector ||
           f.selector == sig:claimRedeem(uint256,address,address).selector;
}

// Verify that each storage layout is only modified in the corresponding functions
rule storageAffected(method f) filtered { f -> f.selector != sig:upgradeToAndCall(address,bytes).selector } {
    env e;

    bool dep;
    address anyAddr;
    address anyAddr2;
    uint256 anyGen;

    mathint wardsBefore = wards(anyAddr);
    mathint lockTimeBgnBefore = lockTimeBgn();
    mathint lockTimeEndBefore = lockTimeEnd();
    mathint periodBefore = period();
    mathint startDayBefore = startDay();
    mathint lastSettleDayBefore = lastSettleDay();
    mathint genBefore = qGen(dep);
    mathint totalUnitsBefore = qTotalUnits(dep);
    mathint pendingBefore = qPending(dep);
    mathint convertedPerUnitBefore = qConvertedPerUnit(dep, anyGen);
    mathint posGenBefore = posGen(dep, anyAddr);
    mathint posUnitsBefore = posUnits(dep, anyAddr);
    mathint posLastBefore = posLast(dep, anyAddr);
    mathint posClaimableBefore = posClaimable(dep, anyAddr);
    bool isOperatorBefore = isOperator(anyAddr, anyAddr2);

    calldataarg args;
    f(e, args);

    mathint wardsAfter = wards(anyAddr);
    mathint lockTimeBgnAfter = lockTimeBgn();
    mathint lockTimeEndAfter = lockTimeEnd();
    mathint periodAfter = period();
    mathint startDayAfter = startDay();
    mathint lastSettleDayAfter = lastSettleDay();
    mathint genAfter = qGen(dep);
    mathint totalUnitsAfter = qTotalUnits(dep);
    mathint pendingAfter = qPending(dep);
    mathint convertedPerUnitAfter = qConvertedPerUnit(dep, anyGen);
    mathint posGenAfter = posGen(dep, anyAddr);
    mathint posUnitsAfter = posUnits(dep, anyAddr);
    mathint posLastAfter = posLast(dep, anyAddr);
    mathint posClaimableAfter = posClaimable(dep, anyAddr);
    bool isOperatorAfter = isOperator(anyAddr, anyAddr2);

    // The functions of the queue `dep` stands for
    bool isQueue  = dep ? f.selector == sig:queueDeposit(uint256,address,address,uint16).selector
                        : f.selector == sig:queueRedeem(uint256,address,address).selector;
    bool isCancel = dep ? f.selector == sig:cancelDeposit(address,address).selector
                        : f.selector == sig:cancelRedeem(address,address).selector;
    bool isClaim  = dep ? f.selector == sig:claimDeposit(uint256,address,address).selector
                        : f.selector == sig:claimRedeem(uint256,address,address).selector;
    bool isSettle = f.selector == sig:settle(int256,uint256,uint256).selector;
    bool isFile   = f.selector == sig:file(bytes32,uint256).selector;

    assert wardsAfter != wardsBefore                       => f.selector == sig:initialize().selector ||
                                                              f.selector == sig:rely(address).selector ||
                                                              f.selector == sig:deny(address).selector;
    assert lockTimeBgnAfter != lockTimeBgnBefore           => isFile;
    assert lockTimeEndAfter != lockTimeEndBefore           => isFile;
    assert periodAfter != periodBefore                     => isFile;
    assert startDayAfter != startDayBefore                 => isFile;
    assert lastSettleDayAfter != lastSettleDayBefore       => isSettle;
    assert genAfter != genBefore                           => isSettle;
    assert totalUnitsAfter != totalUnitsBefore             => isQueue || isCancel || isSettle;
    assert pendingAfter != pendingBefore                   => isQueue || isCancel || isSettle;
    assert convertedPerUnitAfter != convertedPerUnitBefore => isSettle;
    assert posGenAfter != posGenBefore                     => isQueue || isCancel || isClaim;
    assert posUnitsAfter != posUnitsBefore                 => isQueue || isCancel || isClaim;
    assert posLastAfter != posLastBefore                   => isQueue || isCancel || isClaim;
    assert posClaimableAfter != posClaimableBefore         => isQueue || isCancel || isClaim;
    assert isOperatorAfter != isOperatorBefore             => f.selector == sig:setOperator(address,bool).selector;
}

// --- Administration ---

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

// "lockTimeBgn", "lockTimeEnd", "period" and "startDay"
definition WHAT_LOCK_TIME_BGN() returns bytes32 = to_bytes32(0x6c6f636b54696d6542676e000000000000000000000000000000000000000000);
definition WHAT_LOCK_TIME_END() returns bytes32 = to_bytes32(0x6c6f636b54696d65456e64000000000000000000000000000000000000000000);
definition WHAT_PERIOD()        returns bytes32 = to_bytes32(0x706572696f640000000000000000000000000000000000000000000000000000);
definition WHAT_START_DAY()     returns bytes32 = to_bytes32(0x7374617274446179000000000000000000000000000000000000000000000000);

// Verify correct storage changes for non reverting file
rule file(bytes32 what, uint256 data) {
    env e;

    mathint lockTimeBgnBefore = lockTimeBgn();
    mathint lockTimeEndBefore = lockTimeEnd();
    mathint periodBefore = period();
    mathint startDayBefore = startDay();

    file(e, what, data);

    mathint lockTimeBgnAfter = lockTimeBgn();
    mathint lockTimeEndAfter = lockTimeEnd();
    mathint periodAfter = period();
    mathint startDayAfter = startDay();

    assert what == WHAT_LOCK_TIME_BGN() => lockTimeBgnAfter == to_mathint(data);
    assert what != WHAT_LOCK_TIME_BGN() => lockTimeBgnAfter == lockTimeBgnBefore;
    assert what == WHAT_LOCK_TIME_END() => lockTimeEndAfter == to_mathint(data);
    assert what != WHAT_LOCK_TIME_END() => lockTimeEndAfter == lockTimeEndBefore;
    assert what == WHAT_PERIOD()        => periodAfter == to_mathint(data);
    assert what != WHAT_PERIOD()        => periodAfter == periodBefore;
    assert what == WHAT_START_DAY()     => startDayAfter == to_mathint(data);
    assert what != WHAT_START_DAY()     => startDayAfter == startDayBefore;
}

// Verify revert rules on file
rule file_revert(bytes32 what, uint256 data) {
    env e;

    mathint wardsSender = wards(e.msg.sender);
    mathint lockTimeBgn = lockTimeBgn();
    mathint lockTimeEnd = lockTimeEnd();

    file@withrevert(e, what, data);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;
    bool revert3 = what != WHAT_LOCK_TIME_BGN() && what != WHAT_LOCK_TIME_END() &&
                   what != WHAT_PERIOD() && what != WHAT_START_DAY();
    bool revert4 = what == WHAT_LOCK_TIME_BGN() && (data >= DAY() || data >= lockTimeEnd);
    bool revert5 = what == WHAT_LOCK_TIME_END() && (data > DAY() || data <= lockTimeBgn);
    bool revert6 = what == WHAT_PERIOD() && (data == 0 || data > max_uint32);
    bool revert7 = what == WHAT_START_DAY() && data > max_uint32;

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6 ||
                            revert7;
}

// --- Settlement ---

// Verify correct storage changes for non reverting settle
rule settle(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) {
    env e;

    // The price both queues convert at: the one the share is left with by its own settle
    mathint chiCalc = share.chiAfterSettle();

    mathint dGenBefore = qGen(true);
    mathint dTotalUnitsBefore = qTotalUnits(true);
    mathint dPendingBefore = qPending(true);
    mathint dConvertedPerUnitBefore = qConvertedPerUnit(true, assert_uint256(dGenBefore));
    mathint rGenBefore = qGen(false);
    mathint rTotalUnitsBefore = qTotalUnits(false);
    mathint rPendingBefore = qPending(false);
    mathint rConvertedPerUnitBefore = qConvertedPerUnit(false, assert_uint256(rGenBefore));

    // Deposit queue: assets into shares
    mathint dConvertedCalc = _min(depositCapacity, dPendingBefore);
    mathint dReceivedCalc = dConvertedCalc > 0 && chiCalc > 0 ? dConvertedCalc * RAY() / chiCalc : 0;
    mathint dPerUnitCalc = dConvertedCalc > 0 && dTotalUnitsBefore > 0 ? dReceivedCalc * RAY() / dTotalUnitsBefore : 0;
    // Redeem queue: shares into assets
    mathint rConvertedCalc = _min(redeemCapacity, rPendingBefore);
    mathint rReceivedCalc = rConvertedCalc * chiCalc / RAY();
    mathint rPerUnitCalc = rConvertedCalc > 0 && rTotalUnitsBefore > 0 ? rReceivedCalc * RAY() / rTotalUnitsBefore : 0;

    mathint assetBalanceOfQueuesBefore = asset.balanceOf(currentContract);
    mathint shareBalanceOfQueuesBefore = share.balanceOf(currentContract);

    settle(e, profit, depositCapacity, redeemCapacity);

    mathint lastSettleDayAfter = lastSettleDay();
    mathint chiAfter = share.chi();
    mathint dGenAfter = qGen(true);
    mathint dTotalUnitsAfter = qTotalUnits(true);
    mathint dPendingAfter = qPending(true);
    mathint dConvertedPerUnitAfter = qConvertedPerUnit(true, assert_uint256(dGenBefore));
    mathint rGenAfter = qGen(false);
    mathint rTotalUnitsAfter = qTotalUnits(false);
    mathint rPendingAfter = qPending(false);
    mathint rConvertedPerUnitAfter = qConvertedPerUnit(false, assert_uint256(rGenBefore));
    mathint assetBalanceOfQueuesAfter = asset.balanceOf(currentContract);
    mathint shareBalanceOfQueuesAfter = share.balanceOf(currentContract);

    // The day is recorded as settled, and the share was revalued before converting
    assert lastSettleDayAfter == dayOf(e) % 2^32;
    assert chiAfter == chiCalc;
    // Deposit queue: the generation ends only when a conversion takes everything that was pending
    assert dPendingAfter == dPendingBefore - dConvertedCalc;
    assert dConvertedPerUnitAfter == dConvertedPerUnitBefore + dPerUnitCalc;
    assert dConvertedCalc > 0 && dConvertedCalc == dPendingBefore => dGenAfter == dGenBefore + 1;
    assert dConvertedCalc > 0 && dConvertedCalc == dPendingBefore => dTotalUnitsAfter == 0;
    assert dConvertedCalc == 0 || dConvertedCalc < dPendingBefore => dGenAfter == dGenBefore;
    assert dConvertedCalc == 0 || dConvertedCalc < dPendingBefore => dTotalUnitsAfter == dTotalUnitsBefore;
    // Redeem queue
    assert rPendingAfter == rPendingBefore - rConvertedCalc;
    assert rConvertedPerUnitAfter == rConvertedPerUnitBefore + rPerUnitCalc;
    assert rConvertedCalc > 0 && rConvertedCalc == rPendingBefore => rGenAfter == rGenBefore + 1;
    assert rConvertedCalc > 0 && rConvertedCalc == rPendingBefore => rTotalUnitsAfter == 0;
    assert rConvertedCalc == 0 || rConvertedCalc < rPendingBefore => rGenAfter == rGenBefore;
    assert rConvertedCalc == 0 || rConvertedCalc < rPendingBefore => rTotalUnitsAfter == rTotalUnitsBefore;
    // What was converted leaves the queues and what was received stays in them, to be claimed
    assert assetBalanceOfQueuesAfter == assetBalanceOfQueuesBefore - dConvertedCalc + rReceivedCalc;
    assert shareBalanceOfQueuesAfter == shareBalanceOfQueuesBefore + dReceivedCalc - rConvertedCalc;
}

// Verify revert rules on settle
rule settle_revert(int256 profit, uint256 depositCapacity, uint256 redeemCapacity) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    bool lockedReverts = lockedReverts(e);
    bool locked = isLocked(e);

    mathint chiCalc = share.chiAfterSettle();

    mathint dGen = qGen(true);
    mathint dTotalUnits = qTotalUnits(true);
    mathint dPending = qPending(true);
    mathint dConvertedPerUnit = qConvertedPerUnit(true, assert_uint256(dGen));
    mathint rGen = qGen(false);
    mathint rTotalUnits = qTotalUnits(false);
    mathint rPending = qPending(false);
    mathint rConvertedPerUnit = qConvertedPerUnit(false, assert_uint256(rGen));

    mathint dConvertedCalc = _min(depositCapacity, dPending);
    mathint dReceivedCalc = dConvertedCalc > 0 && chiCalc > 0 ? dConvertedCalc * RAY() / chiCalc : 0;
    mathint dPerUnitCalc = dConvertedCalc > 0 && dTotalUnits > 0 ? dReceivedCalc * RAY() / dTotalUnits : 0;
    mathint rConvertedCalc = _min(redeemCapacity, rPending);
    mathint rReceivedCalc = rConvertedCalc * chiCalc / RAY();
    mathint rPerUnitCalc = rConvertedCalc > 0 && rTotalUnits > 0 ? rReceivedCalc * RAY() / rTotalUnits : 0;

    mathint assetTotalSupply = asset.totalSupply();
    mathint shareTotalSupply = share.totalSupply();

    // Happening in initialize
    require asset.allowance(currentContract, share) == max_uint256;
    // ERC20 correct behaviour
    require assetTotalSupply >= asset.balanceOf(currentContract) + asset.balanceOf(share);
    require shareTotalSupply >= share.balanceOf(currentContract);
    // The queues hold what is pending: what they owe to positions is a sum of amounts that are not negative
    requireInvariant queuesHoldAssetsOwed();
    requireInvariant queuesHoldSharesOwed();
    require owedRay[true] >= 0 && owedRay[false] >= 0;
    // Correct behaviour share: it holds the assets its supply is worth at the settled price, and its own settle
    // does not revert (when it does is verified in the SrUsds spec)
    require asset.balanceOf(share) >= shareTotalSupply * chiCalc / RAY();
    // Convenience assumptions
    require shareTotalSupply + dReceivedCalc <= max_uint256;

    settle@withrevert(e, profit, depositCapacity, redeemCapacity);

    bool revert1  = e.msg.value > 0;
    bool revert2  = wardsSender != 1;
    bool revert3  = lockedReverts;
    bool revert4  = !locked;
    // Deposit queue conversion
    bool revert5  = dConvertedCalc > 0 && dConvertedCalc * RAY() > max_uint256;
    bool revert6  = dConvertedCalc > 0 && chiCalc == 0;
    bool revert7  = dConvertedCalc > 0 && dReceivedCalc * RAY() > max_uint256;
    bool revert8  = dConvertedCalc > 0 && dTotalUnits == 0;
    bool revert9  = dConvertedCalc > 0 && dConvertedPerUnit + dPerUnitCalc > max_uint256;
    bool revert10 = dConvertedCalc > 0 && dConvertedCalc == dPending && dGen == max_uint256;
    // Redeem queue conversion
    bool revert11 = rConvertedCalc > 0 && rConvertedCalc * chiCalc > max_uint256;
    bool revert12 = rConvertedCalc > 0 && rReceivedCalc * RAY() > max_uint256;
    bool revert13 = rConvertedCalc > 0 && rTotalUnits == 0;
    bool revert14 = rConvertedCalc > 0 && rConvertedPerUnit + rPerUnitCalc > max_uint256;
    bool revert15 = rConvertedCalc > 0 && rConvertedCalc == rPending && rGen == max_uint256;

    assert lastReverted <=> revert1  || revert2  || revert3  ||
                            revert4  || revert5  || revert6  ||
                            revert7  || revert8  || revert9  ||
                            revert10 || revert11 || revert12 ||
                            revert13 || revert14 || revert15;
}

// --- Operators ---

// Verify correct storage changes for non reverting setOperator
rule setOperator(address operator, bool approved) {
    env e;

    address otherAddr; address otherAddr2;
    require otherAddr != e.msg.sender || otherAddr2 != operator;

    bool isOperatorOtherBefore = isOperator(otherAddr, otherAddr2);

    bool result = setOperator(e, operator, approved);

    bool isOperatorSenderOperatorAfter = isOperator(e.msg.sender, operator);
    bool isOperatorOtherAfter = isOperator(otherAddr, otherAddr2);

    assert result;
    assert isOperatorSenderOperatorAfter == approved;
    assert isOperatorOtherAfter == isOperatorOtherBefore;
}

// Verify revert rules on setOperator
rule setOperator_revert(address operator, bool approved) {
    env e;

    setOperator@withrevert(e, operator, approved);

    bool revert1 = e.msg.value > 0;

    assert lastReverted <=> revert1;
}

// --- Requests: _queue(queue, token, amount, controller, owner) ---

function checkQueue(env e, bool dep, uint256 amount, address controller, address owner, uint16 referral) {
    // The queues contract is never an owner: it does not call itself and approves no operator
    require owner != currentContract;

    address otherAddr;
    require otherAddr != controller;

    mathint totalUnitsBefore = qTotalUnits(dep);
    mathint pendingBefore = qPending(dep);
    mathint posGenOtherBefore = posGen(dep, otherAddr);
    mathint posUnitsOtherBefore = posUnits(dep, otherAddr);
    mathint posLastOtherBefore = posLast(dep, otherAddr);
    mathint posClaimableOtherBefore = posClaimable(dep, otherAddr);
    mathint underlyingBalanceOfOwnerBefore = underlyingBalanceOf(dep, owner);
    mathint underlyingBalanceOfQueuesBefore = underlyingBalanceOf(dep, currentContract);

    // The controller's position is synced first
    mathint syncGenCalc = syncGen(dep, controller);
    mathint syncUnitsCalc = syncUnits(dep, controller);
    mathint syncLastCalc = syncLast(dep, controller);
    mathint syncClaimableCalc = syncClaimable(dep, controller);
    // Units minted: 1:1 in an empty queue, at the current ratio otherwise
    mathint unitsCalc = totalUnitsBefore == 0 || pendingBefore == 0 ? amount : amount * totalUnitsBefore / pendingBefore;

    // ERC20 correct behaviour
    require underlyingTotalSupply(dep) >= underlyingBalanceOfOwnerBefore + underlyingBalanceOfQueuesBefore;

    if (dep) {
        queueDeposit(e, amount, controller, owner, referral);
    } else {
        queueRedeem(e, amount, controller, owner);
    }

    mathint totalUnitsAfter = qTotalUnits(dep);
    mathint pendingAfter = qPending(dep);
    mathint posGenControllerAfter = posGen(dep, controller);
    mathint posUnitsControllerAfter = posUnits(dep, controller);
    mathint posLastControllerAfter = posLast(dep, controller);
    mathint posClaimableControllerAfter = posClaimable(dep, controller);
    mathint posGenOtherAfter = posGen(dep, otherAddr);
    mathint posUnitsOtherAfter = posUnits(dep, otherAddr);
    mathint posLastOtherAfter = posLast(dep, otherAddr);
    mathint posClaimableOtherAfter = posClaimable(dep, otherAddr);
    mathint underlyingBalanceOfOwnerAfter = underlyingBalanceOf(dep, owner);
    mathint underlyingBalanceOfQueuesAfter = underlyingBalanceOf(dep, currentContract);

    assert totalUnitsAfter == totalUnitsBefore + unitsCalc;
    assert pendingAfter == pendingBefore + amount;
    assert posGenControllerAfter == syncGenCalc;
    assert posUnitsControllerAfter == syncUnitsCalc + unitsCalc;
    assert posLastControllerAfter == syncLastCalc;
    assert posClaimableControllerAfter == syncClaimableCalc;
    assert posGenOtherAfter == posGenOtherBefore;
    assert posUnitsOtherAfter == posUnitsOtherBefore;
    assert posLastOtherAfter == posLastOtherBefore;
    assert posClaimableOtherAfter == posClaimableOtherBefore;
    assert underlyingBalanceOfOwnerAfter == underlyingBalanceOfOwnerBefore - amount;
    assert underlyingBalanceOfQueuesAfter == underlyingBalanceOfQueuesBefore + amount;
}

function checkQueueRevert(env e, bool dep, uint256 amount, address controller, address owner, uint16 referral) {
    // The queues contract is never an owner: it does not call itself and approves no operator
    require owner != currentContract;

    bool allowed = isAllowed(owner, e.msg.sender);
    bool lockedReverts = lockedReverts(e);
    bool locked = isLocked(e);
    bool closedReverts = closedReverts(dep);
    bool closed = isClosed(dep);
    bool syncReverts = syncReverts(dep, controller);

    mathint totalUnits = qTotalUnits(dep);
    mathint pending = qPending(dep);
    mathint syncUnitsCalc = syncUnits(dep, controller);
    mathint unitsCalc = totalUnits == 0 || pending == 0 ? amount : amount * totalUnits / pending;

    // ERC20 correct behaviour
    require underlyingTotalSupply(dep) >= underlyingBalanceOf(dep, owner) + underlyingBalanceOf(dep, currentContract);
    // Owner assumptions
    require underlyingAllowance(dep, owner, currentContract) >= amount;
    require underlyingBalanceOf(dep, owner) >= amount;

    if (dep) {
        queueDeposit@withrevert(e, amount, controller, owner, referral);
    } else {
        queueRedeem@withrevert(e, amount, controller, owner);
    }

    bool revert1  = e.msg.value > 0;
    bool revert2  = !allowed;
    bool revert3  = controller == 0 || controller == currentContract;
    bool revert4  = amount == 0;
    bool revert5  = lockedReverts;
    bool revert6  = locked;
    bool revert7  = closedReverts;
    bool revert8  = closed;
    bool revert9  = syncReverts;
    bool revert10 = totalUnits != 0 && amount * totalUnits > max_uint256;
    bool revert11 = pending + amount > max_uint256;
    bool revert12 = totalUnits + unitsCalc > max_uint256;
    bool revert13 = syncUnitsCalc + unitsCalc > max_uint256;

    assert lastReverted <=> revert1  || revert2  || revert3  ||
                            revert4  || revert5  || revert6  ||
                            revert7  || revert8  || revert9  ||
                            revert10 || revert11 || revert12 ||
                            revert13;
}

// Verify correct storage changes for non reverting queueDeposit
rule queueDeposit(uint256 assets, address controller, address owner, uint16 referral) {
    env e;

    checkQueue(e, true, assets, controller, owner, referral);
}

// Verify revert rules on queueDeposit
rule queueDeposit_revert(uint256 assets, address controller, address owner, uint16 referral) {
    env e;

    checkQueueRevert(e, true, assets, controller, owner, referral);
}

// Verify correct storage changes for non reverting queueRedeem
rule queueRedeem(uint256 shares, address controller, address owner) {
    env e;

    uint16 referral;
    checkQueue(e, false, shares, controller, owner, referral);
}

// Verify revert rules on queueRedeem
rule queueRedeem_revert(uint256 shares, address controller, address owner) {
    env e;

    uint16 referral;
    checkQueueRevert(e, false, shares, controller, owner, referral);
}

// --- Cancellations: _cancel(queue, token, receiver, controller) ---

function checkCancel(env e, bool dep, address receiver, address controller) {
    address otherAddr;
    require otherAddr != controller;

    mathint totalUnitsBefore = qTotalUnits(dep);
    mathint pendingBefore = qPending(dep);
    mathint posGenOtherBefore = posGen(dep, otherAddr);
    mathint posUnitsOtherBefore = posUnits(dep, otherAddr);
    mathint posLastOtherBefore = posLast(dep, otherAddr);
    mathint posClaimableOtherBefore = posClaimable(dep, otherAddr);
    mathint underlyingBalanceOfReceiverBefore = underlyingBalanceOf(dep, receiver);
    mathint underlyingBalanceOfQueuesBefore = underlyingBalanceOf(dep, currentContract);

    // The controller's position is synced first
    mathint syncGenCalc = syncGen(dep, controller);
    mathint syncUnitsCalc = syncUnits(dep, controller);
    mathint syncLastCalc = syncLast(dep, controller);
    mathint syncClaimableCalc = syncClaimable(dep, controller);
    // Its share of what is still pending, rounded down
    mathint amountCalc = totalUnitsBefore == 0 ? 0 : syncUnitsCalc * pendingBefore / totalUnitsBefore;

    // ERC20 correct behaviour
    require underlyingTotalSupply(dep) >= underlyingBalanceOfReceiverBefore + underlyingBalanceOfQueuesBefore;

    mathint amount = dep ? cancelDeposit(e, receiver, controller) : cancelRedeem(e, receiver, controller);

    mathint totalUnitsAfter = qTotalUnits(dep);
    mathint pendingAfter = qPending(dep);
    mathint posGenControllerAfter = posGen(dep, controller);
    mathint posUnitsControllerAfter = posUnits(dep, controller);
    mathint posLastControllerAfter = posLast(dep, controller);
    mathint posClaimableControllerAfter = posClaimable(dep, controller);
    mathint posGenOtherAfter = posGen(dep, otherAddr);
    mathint posUnitsOtherAfter = posUnits(dep, otherAddr);
    mathint posLastOtherAfter = posLast(dep, otherAddr);
    mathint posClaimableOtherAfter = posClaimable(dep, otherAddr);
    mathint underlyingBalanceOfReceiverAfter = underlyingBalanceOf(dep, receiver);
    mathint underlyingBalanceOfQueuesAfter = underlyingBalanceOf(dep, currentContract);

    assert amount == amountCalc;
    assert totalUnitsAfter == totalUnitsBefore - syncUnitsCalc;
    assert pendingAfter == pendingBefore - amountCalc;
    assert posGenControllerAfter == syncGenCalc;
    assert posUnitsControllerAfter == 0;
    assert posLastControllerAfter == syncLastCalc;
    assert posClaimableControllerAfter == syncClaimableCalc;
    assert posGenOtherAfter == posGenOtherBefore;
    assert posUnitsOtherAfter == posUnitsOtherBefore;
    assert posLastOtherAfter == posLastOtherBefore;
    assert posClaimableOtherAfter == posClaimableOtherBefore;
    assert underlyingBalanceOfReceiverAfter == underlyingBalanceOfReceiverBefore + amountCalc;
    assert underlyingBalanceOfQueuesAfter == underlyingBalanceOfQueuesBefore - amountCalc;
}

function checkCancelRevert(env e, bool dep, address receiver, address controller) {
    bool allowed = isAllowed(controller, e.msg.sender);
    bool lockedReverts = lockedReverts(e);
    bool locked = isLocked(e);
    bool syncReverts = syncReverts(dep, controller);

    address underlyingToken = underlyingToken(dep);

    mathint totalUnits = qTotalUnits(dep);
    mathint pending = qPending(dep);
    mathint syncUnitsCalc = syncUnits(dep, controller);
    mathint amountCalc = totalUnits == 0 ? 0 : syncUnitsCalc * pending / totalUnits;

    // ERC20 correct behaviour
    require underlyingTotalSupply(dep) >= underlyingBalanceOf(dep, receiver) + underlyingBalanceOf(dep, currentContract);
    // The queues hold what is pending: what they owe to positions is a sum of amounts that are not negative
    requireInvariant queuesHoldAssetsOwed();
    requireInvariant queuesHoldSharesOwed();
    require owedRay[true] >= 0 && owedRay[false] >= 0;

    if (dep) {
        cancelDeposit@withrevert(e, receiver, controller);
    } else {
        cancelRedeem@withrevert(e, receiver, controller);
    }

    bool revert1 = e.msg.value > 0;
    bool revert2 = !allowed;
    bool revert3 = receiver == 0 || receiver == currentContract;
    bool revert4 = lockedReverts;
    bool revert5 = locked;
    bool revert6 = syncReverts;
    bool revert7 = totalUnits != 0 && syncUnitsCalc * pending > max_uint256;
    bool revert8 = amountCalc > pending;
    bool revert9 = syncUnitsCalc > totalUnits;
    // The token rejects itself as a recipient
    bool revert10 = receiver == underlyingToken;

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6 ||
                            revert7 || revert8 || revert9 ||
                            revert10;
}

// Verify correct storage changes for non reverting cancelDeposit
rule cancelDeposit(address receiver, address controller) {
    env e;

    checkCancel(e, true, receiver, controller);
}

// Verify revert rules on cancelDeposit
rule cancelDeposit_revert(address receiver, address controller) {
    env e;

    checkCancelRevert(e, true, receiver, controller);
}

// Verify correct storage changes for non reverting cancelRedeem
rule cancelRedeem(address receiver, address controller) {
    env e;

    checkCancel(e, false, receiver, controller);
}

// Verify revert rules on cancelRedeem
rule cancelRedeem_revert(address receiver, address controller) {
    env e;

    checkCancelRevert(e, false, receiver, controller);
}

// --- Claims: _claim(queue, token, amount, receiver, controller) ---

function checkClaim(env e, bool dep, uint256 amount, address receiver, address controller) {
    address otherAddr;
    require otherAddr != controller;

    mathint posGenOtherBefore = posGen(dep, otherAddr);
    mathint posUnitsOtherBefore = posUnits(dep, otherAddr);
    mathint posLastOtherBefore = posLast(dep, otherAddr);
    mathint posClaimableOtherBefore = posClaimable(dep, otherAddr);
    mathint convertedBalanceOfReceiverBefore = convertedBalanceOf(dep, receiver);
    mathint convertedBalanceOfQueuesBefore = convertedBalanceOf(dep, currentContract);

    // The controller's position is synced first
    mathint syncGenCalc = syncGen(dep, controller);
    mathint syncUnitsCalc = syncUnits(dep, controller);
    mathint syncLastCalc = syncLast(dep, controller);
    mathint syncClaimableCalc = syncClaimable(dep, controller);
    // The maximum value claims everything
    mathint claimedCalc = amount == max_uint256 ? syncClaimableCalc : amount;

    // ERC20 correct behaviour
    require convertedTotalSupply(dep) >= convertedBalanceOfReceiverBefore + convertedBalanceOfQueuesBefore;

    mathint claimed = dep ? claimDeposit(e, amount, receiver, controller) : claimRedeem(e, amount, receiver, controller);

    mathint posGenControllerAfter = posGen(dep, controller);
    mathint posUnitsControllerAfter = posUnits(dep, controller);
    mathint posLastControllerAfter = posLast(dep, controller);
    mathint posClaimableControllerAfter = posClaimable(dep, controller);
    mathint posGenOtherAfter = posGen(dep, otherAddr);
    mathint posUnitsOtherAfter = posUnits(dep, otherAddr);
    mathint posLastOtherAfter = posLast(dep, otherAddr);
    mathint posClaimableOtherAfter = posClaimable(dep, otherAddr);
    mathint convertedBalanceOfReceiverAfter = convertedBalanceOf(dep, receiver);
    mathint convertedBalanceOfQueuesAfter = convertedBalanceOf(dep, currentContract);

    assert claimed == claimedCalc;
    assert posGenControllerAfter == syncGenCalc;
    assert posUnitsControllerAfter == syncUnitsCalc;
    assert posLastControllerAfter == syncLastCalc;
    assert posClaimableControllerAfter == syncClaimableCalc - claimedCalc;
    assert posGenOtherAfter == posGenOtherBefore;
    assert posUnitsOtherAfter == posUnitsOtherBefore;
    assert posLastOtherAfter == posLastOtherBefore;
    assert posClaimableOtherAfter == posClaimableOtherBefore;
    assert convertedBalanceOfReceiverAfter == convertedBalanceOfReceiverBefore + claimedCalc;
    assert convertedBalanceOfQueuesAfter == convertedBalanceOfQueuesBefore - claimedCalc;
}

function checkClaimRevert(env e, bool dep, uint256 amount, address receiver, address controller) {
    bool allowed = isAllowed(controller, e.msg.sender);
    bool syncReverts = syncReverts(dep, controller);

    address convertedToken = convertedToken(dep);

    mathint syncClaimableCalc = syncClaimable(dep, controller);

    // ERC20 correct behaviour
    require convertedTotalSupply(dep) >= convertedBalanceOf(dep, receiver) + convertedBalanceOf(dep, currentContract);
    // The queues hold what is claimable: what they owe to all positions is at least what they owe to this one
    requireInvariant queuesHoldAssetsOwed();
    requireInvariant queuesHoldSharesOwed();
    require owedRay[dep] >= posOwedRay(dep, controller);

    if (dep) {
        claimDeposit@withrevert(e, amount, receiver, controller);
    } else {
        claimRedeem@withrevert(e, amount, receiver, controller);
    }

    bool revert1 = e.msg.value > 0;
    bool revert2 = !allowed;
    bool revert3 = receiver == 0 || receiver == currentContract;
    bool revert4 = syncReverts;
    bool revert5 = amount != max_uint256 && amount > syncClaimableCalc;
    // The token rejects itself as a recipient
    bool revert6 = receiver == convertedToken;

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6;
}

// Verify correct storage changes for non reverting claimDeposit
rule claimDeposit(uint256 shares, address receiver, address controller) {
    env e;

    checkClaim(e, true, shares, receiver, controller);
}

// Verify revert rules on claimDeposit
rule claimDeposit_revert(uint256 shares, address receiver, address controller) {
    env e;

    checkClaimRevert(e, true, shares, receiver, controller);
}

// Verify correct storage changes for non reverting claimRedeem
rule claimRedeem(uint256 assets, address receiver, address controller) {
    env e;

    checkClaim(e, false, assets, receiver, controller);
}

// Verify revert rules on claimRedeem
rule claimRedeem_revert(uint256 assets, address receiver, address controller) {
    env e;

    checkClaimRevert(e, false, assets, receiver, controller);
}

// --- Views ---

// Verify correct behaviour of locked getter
rule locked() {
    env e;

    bool lockedCalc = isLocked(e);

    bool locked = locked(e);

    assert locked == lockedCalc;
}

// Verify revert rules on locked
rule locked_revert() {
    env e;

    bool lockedReverts = lockedReverts(e);

    locked@withrevert(e);

    bool revert1 = e.msg.value > 0;
    bool revert2 = lockedReverts;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct behaviour of isQueueDepositClosed getter
rule isQueueDepositClosed() {
    bool closedCalc = isClosed(true);

    bool closed = isQueueDepositClosed();

    assert closed == closedCalc;
}

// Verify correct behaviour of isQueueRedeemClosed getter
rule isQueueRedeemClosed() {
    bool closedCalc = isClosed(false);

    bool closed = isQueueRedeemClosed();

    assert closed == closedCalc;
}

// Verify correct behaviour of pendingDeposit getter
rule pendingDeposit(address controller) {
    mathint pendingCalc = pendingCalc(true, controller);

    mathint pending = pendingDeposit(controller);

    assert pending == pendingCalc;
}

// Verify correct behaviour of pendingRedeem getter
rule pendingRedeem(address controller) {
    mathint pendingCalc = pendingCalc(false, controller);

    mathint pending = pendingRedeem(controller);

    assert pending == pendingCalc;
}

// Verify correct behaviour of claimableDeposit getter
rule claimableDeposit(address controller) {
    mathint claimableCalc = syncClaimable(true, controller);

    mathint claimable = claimableDeposit(controller);

    assert claimable == claimableCalc;
}

// Verify correct behaviour of claimableRedeem getter
rule claimableRedeem(address controller) {
    mathint claimableCalc = syncClaimable(false, controller);

    mathint claimable = claimableRedeem(controller);

    assert claimable == claimableCalc;
}
