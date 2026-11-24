// SrUsdsMom.spec

using SrUsdsBeam as beam;

methods {
    // storage variables
    function owner() external returns (address) envfree;
    function authority() external returns (address) envfree;
    //
    function beam.wards(address) external returns (uint256) envfree;
    function beam.bad() external returns (uint8) envfree;
    //
    function _.file(bytes32, uint256) external => DISPATCHER(true);
    function _.canCall(address, address, bytes4) external => canCallSummary() expect bool;
}

persistent ghost bool retCanCall;
function canCallSummary() returns bool {
    return retCanCall;
}

// Verify no more entry points exist
rule entryPoints(method f) filtered { f -> !f.isView } {
    env e;

    calldataarg args;
    f(e, args);

    assert f.selector == sig:setOwner(address).selector ||
           f.selector == sig:setAuthority(address).selector ||
           f.selector == sig:haltBeam(address).selector;
}

// Verify that each storage layout is only modified in the corresponding functions
rule storageAffected(method f) {
    env e;

    address ownerBefore = owner();
    address authorityBefore = authority();

    calldataarg args;
    f(e, args);

    address ownerAfter = owner();
    address authorityAfter = authority();

    assert ownerAfter != ownerBefore         => f.selector == sig:setOwner(address).selector;
    assert authorityAfter != authorityBefore => f.selector == sig:setAuthority(address).selector;
}

// Verify correct storage changes for non reverting setOwner
rule setOwner(address owner_) {
    env e;

    setOwner(e, owner_);

    address ownerAfter = owner();

    assert ownerAfter == owner_;
}

// Verify revert rules on setOwner
rule setOwner_revert(address owner_) {
    env e;

    address owner = owner();

    setOwner@withrevert(e, owner_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = owner != e.msg.sender;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct storage changes for non reverting setAuthority
rule setAuthority(address authority_) {
    env e;

    setAuthority(e, authority_);

    address authorityAfter = authority();

    assert authorityAfter == authority_;
}

// Verify revert rules on setAuthority
rule setAuthority_revert(address authority_) {
    env e;

    address owner = owner();

    setAuthority@withrevert(e, authority_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = owner != e.msg.sender;

    assert lastReverted <=> revert1 || revert2;
}

// Verify correct storage changes for non reverting haltBeam
rule haltBeam(address beam_) {
    env e;

    require beam_ == beam;

    haltBeam(e, beam_);

    mathint beamBadAfter = beam.bad();

    assert beamBadAfter == 1;
}

// Verify revert rules on haltBeam
rule haltBeam_revert(address beam_) {
    env e;

    require beam_ == beam;

    address owner = owner();
    address authority = authority();

    // Happening in init scripts
    require beam.wards(currentContract) == 1;

    haltBeam@withrevert(e, beam_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = owner != e.msg.sender && (authority == 0 || !retCanCall);

    assert lastReverted <=> revert1 || revert2;
}
