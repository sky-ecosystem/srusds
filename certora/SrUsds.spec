// SrUsds.spec

using Vat as vat;
using UsdsJoinMock as usdsJoin;
using UsdsMock as usds;
using SUsdsMock as susds;
using SignerMock as signer;
using Auxiliar as aux;

methods {
    // storage variables
    function wards(address) external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function allowance(address, address) external returns (uint256) envfree;
    function nonces(address) external returns (uint256) envfree;
    function chi() external returns (uint192) envfree;
    // immutables
    function usdsJoin() external returns (address) envfree;
    function vat() external returns (address) envfree;
    function usds() external returns (address) envfree;
    function vow() external returns (address) envfree;
    function susds() external returns (address) envfree;
    //
    function DOMAIN_SEPARATOR() external returns (bytes32) envfree;
    function PERMIT_TYPEHASH() external returns (bytes32) envfree;
    //
    function vat.wards(address) external returns (uint256) envfree;
    function vat.can(address, address) external returns (uint256) envfree;
    function vat.vice() external returns (uint256) envfree;
    function vat.debt() external returns (uint256) envfree;
    function vat.dai(address) external returns (uint256) envfree;
    function vat.sin(address) external returns (uint256) envfree;
    function usds.allowance(address, address) external returns (uint256) envfree;
    function usds.balanceOf(address) external returns (uint256) envfree;
    function usds.totalSupply() external returns (uint256) envfree;
    function susds.allowance(address, address) external returns (uint256) envfree;
    function susds.balanceOf(address) external returns (uint256) envfree;
    function susds.totalSupply() external returns (uint256) envfree;
    function susds.chi() external returns (uint256) envfree;
    function aux.call_ecrecover(bytes32, uint8, bytes32, bytes32) external returns (address) envfree;
    function aux.computeDigestForToken(bytes32, bytes32, address, address, uint256, uint256, uint256) external returns (bytes32) envfree;
    function aux.signatureToVRS(bytes) external returns (uint8, bytes32, bytes32) envfree;
    function aux.VRSToSignature(uint8, bytes32, bytes32) external returns (bytes) envfree;
    function aux.size(bytes) external returns (uint256) envfree;
    //
    function _.isValidSignature(bytes32, bytes) external => DISPATCHER(true);
}

definition RAY() returns mathint = 10^27;
definition MAX_UINT192() returns mathint = 2^192 - 1;
definition MIN_INT256() returns mathint = -2^255;
definition _divup(mathint x, mathint y) returns mathint = x != 0 ? ((x - 1) / y) + 1 : 0;

definition defConvertToShares(mathint assets) returns mathint = chi() > 0 ? assets * RAY() / chi() : 0;
definition defConvertToAssets(mathint shares) returns mathint = shares * chi() / RAY();
definition defTotalAssets() returns mathint = totalSupply() * chi() / RAY();

ghost balanceSum() returns mathint {
    init_state axiom balanceSum() == 0;
}
hook Sstore balanceOf[KEY address a] uint256 balance (uint256 old_balance) {
    havoc balanceSum assuming balanceSum@new() == balanceSum@old() + balance - old_balance && balanceSum@new() >= 0;
}
invariant balanceSum_equals_totalSupply() balanceSum() == to_mathint(totalSupply())
            filtered {
                f -> f.selector != sig:upgradeToAndCall(address, bytes).selector
            }

// The sUSDS held covers what the outstanding shares are worth. Stated in ray, without the division of
// totalAssets, which is stronger: susds.balanceOf >= totalSupply * chi / RAY follows from it
invariant susdsBalance_greater_or_equal_than_totalAssets() susds.balanceOf(currentContract) * RAY() >= totalSupply() * chi()
            filtered {
                f -> f.selector != sig:upgradeToAndCall(address, bytes).selector &&
                     f.selector != sig:initialize().selector
            } {
            preserved with (env e) {
                require e.msg.sender != currentContract;
                requireInvariant balanceSum_equals_totalSupply;
            }
}

rule entryPoints(method f) filtered { f -> !f.isView } {
    env e;

    calldataarg args;
    f(e, args);

    assert f.selector == sig:initialize().selector ||
           f.selector == sig:upgradeToAndCall(address,bytes).selector ||
           f.selector == sig:rely(address).selector ||
           f.selector == sig:deny(address).selector ||
           f.selector == sig:settle(int256).selector ||
           f.selector == sig:transfer(address,uint256).selector ||
           f.selector == sig:transferFrom(address,address,uint256).selector ||
           f.selector == sig:approve(address,uint256).selector ||
           f.selector == sig:deposit(uint256,address).selector ||
           f.selector == sig:redeem(uint256,address,address).selector ||
           f.selector == sig:permit(address,address,uint256,uint256,bytes).selector ||
           f.selector == sig:permit(address,address,uint256,uint256,uint8,bytes32,bytes32).selector;
}

// Verify that each storage layout is only modified in the corresponding functions
rule storageAffected(method f) filtered { f -> f.selector != sig:upgradeToAndCall(address,bytes).selector } {
    env e;

    address anyAddr;
    address anyAddr2;

    mathint wardsBefore = wards(anyAddr);
    mathint totalSupplyBefore = totalSupply();
    mathint balanceOfBefore = balanceOf(anyAddr);
    mathint allowanceBefore = allowance(anyAddr, anyAddr2);
    mathint noncesBefore = nonces(anyAddr);
    mathint chiBefore = chi();

    calldataarg args;
    f(e, args);

    mathint wardsAfter = wards(anyAddr);
    mathint totalSupplyAfter = totalSupply();
    mathint balanceOfAfter = balanceOf(anyAddr);
    mathint allowanceAfter = allowance(anyAddr, anyAddr2);
    mathint noncesAfter = nonces(anyAddr);
    mathint chiAfter = chi();

    assert wardsAfter != wardsBefore             => f.selector == sig:initialize().selector ||
                                                    f.selector == sig:rely(address).selector ||
                                                    f.selector == sig:deny(address).selector;
    assert totalSupplyAfter != totalSupplyBefore => f.selector == sig:deposit(uint256,address).selector ||
                                                    f.selector == sig:redeem(uint256,address,address).selector;
    assert balanceOfAfter != balanceOfBefore     => f.selector == sig:deposit(uint256,address).selector ||
                                                    f.selector == sig:redeem(uint256,address,address).selector ||
                                                    f.selector == sig:transfer(address,uint256).selector ||
                                                    f.selector == sig:transferFrom(address,address,uint256).selector;
    assert allowanceAfter != allowanceBefore     => f.selector == sig:approve(address,uint256).selector ||
                                                    f.selector == sig:transferFrom(address,address,uint256).selector ||
                                                    f.selector == sig:redeem(uint256,address,address).selector ||
                                                    f.selector == sig:permit(address,address,uint256,uint256,bytes).selector ||
                                                    f.selector == sig:permit(address,address,uint256,uint256,uint8,bytes32,bytes32).selector;
    assert noncesAfter != noncesBefore           => f.selector == sig:permit(address,address,uint256,uint256,bytes).selector ||
                                                    f.selector == sig:permit(address,address,uint256,uint256,uint8,bytes32,bytes32).selector;
    assert chiAfter != chiBefore                 => f.selector == sig:initialize().selector ||
                                                    f.selector == sig:settle(int256).selector;
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

// Verify correct storage changes for non reverting settle
rule settle(int256 assets) {
    env e;

    address vow = vow();

    // Correct vow set
    require vow != currentContract && vow != usdsJoin;

    mathint chiBefore = chi();
    mathint totalSupply = totalSupply();
    mathint totalAssetsBefore = defTotalAssets();
    mathint susdsChi = susds.chi();

    // Gain: USDS generated to mint exactly `assets` sUSDS
    mathint gainUsds = _divup(assets * susdsChi, RAY());
    // Loss: sUSDS removed, and the USDS it is redeemed for
    mathint lossAssets = -assets;
    mathint lossUsds = lossAssets * susdsChi / RAY();

    mathint susdsBalanceOfSrUsdsBefore = susds.balanceOf(currentContract);
    mathint susdsTotalSupplyBefore = susds.totalSupply();
    mathint usdsBalanceOfSrUsdsBefore = usds.balanceOf(currentContract);
    mathint usdsTotalSupplyBefore = usds.totalSupply();
    mathint vatSinVowBefore = vat.sin(vow);
    mathint vatDaiVowBefore = vat.dai(vow);
    mathint vatDaiUsdsJoinBefore = vat.dai(usdsJoin);
    mathint vatDaiSrUsdsBefore = vat.dai(currentContract);

    settle(e, assets);

    mathint chiAfter = chi();
    mathint susdsBalanceOfSrUsdsAfter = susds.balanceOf(currentContract);
    mathint susdsTotalSupplyAfter = susds.totalSupply();
    mathint usdsBalanceOfSrUsdsAfter = usds.balanceOf(currentContract);
    mathint usdsTotalSupplyAfter = usds.totalSupply();
    mathint vatSinVowAfter = vat.sin(vow);
    mathint vatDaiVowAfter = vat.dai(vow);
    mathint vatDaiUsdsJoinAfter = vat.dai(usdsJoin);
    mathint vatDaiSrUsdsAfter = vat.dai(currentContract);

    // Nothing to settle
    assert assets == 0 => chiAfter == chiBefore;
    assert assets == 0 => susdsBalanceOfSrUsdsAfter == susdsBalanceOfSrUsdsBefore;
    assert assets == 0 => usdsTotalSupplyAfter == usdsTotalSupplyBefore;
    assert assets == 0 => vatSinVowAfter == vatSinVowBefore;
    assert assets == 0 => vatDaiVowAfter == vatDaiVowBefore;
    // Gain
    assert assets > 0 => chiAfter == chiBefore + assets * RAY() / totalSupply;
    assert assets > 0 => susdsBalanceOfSrUsdsAfter == susdsBalanceOfSrUsdsBefore + assets;
    assert assets > 0 => susdsTotalSupplyAfter == susdsTotalSupplyBefore + assets;
    assert assets > 0 => usdsTotalSupplyAfter == usdsTotalSupplyBefore + gainUsds;
    assert assets > 0 => vatSinVowAfter == vatSinVowBefore + gainUsds * RAY();
    assert assets > 0 => vatDaiVowAfter == vatDaiVowBefore;
    assert assets > 0 => vatDaiUsdsJoinAfter == vatDaiUsdsJoinBefore + gainUsds * RAY();
    // Loss
    assert assets < 0 && lossAssets == totalAssetsBefore => chiAfter == 0;
    assert assets < 0 && lossAssets != totalAssetsBefore => chiAfter == chiBefore - _divup(lossAssets * RAY(), totalSupply);
    assert assets < 0 => susdsBalanceOfSrUsdsAfter == susdsBalanceOfSrUsdsBefore - lossAssets;
    assert assets < 0 => susdsTotalSupplyAfter == susdsTotalSupplyBefore - lossAssets;
    assert assets < 0 => usdsTotalSupplyAfter == usdsTotalSupplyBefore - lossUsds;
    assert assets < 0 => vatSinVowAfter == vatSinVowBefore;
    assert assets < 0 => vatDaiVowAfter == vatDaiVowBefore + lossUsds * RAY();
    assert assets < 0 => vatDaiUsdsJoinAfter == vatDaiUsdsJoinBefore - lossUsds * RAY();
    // The USDS only passes through, in any case
    assert usdsBalanceOfSrUsdsAfter == usdsBalanceOfSrUsdsBefore;
    assert vatDaiSrUsdsAfter == vatDaiSrUsdsBefore;
}

// Verify revert rules on settle
rule settle_revert(int256 assets) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    address vow = vow();

    mathint chi = chi();
    mathint totalSupply = totalSupply();
    mathint totalAssets = defTotalAssets();
    mathint susdsChi = susds.chi();

    mathint gainUsds = assets > 0 ? _divup(assets * susdsChi, RAY()) : 0;
    mathint gainChi = assets > 0 && totalSupply > 0 ? assets * RAY() / totalSupply : 0;
    mathint lossAssets = assets < 0 ? -assets : 0;
    mathint lossUsds = lossAssets * susdsChi / RAY();

    mathint usdsTotalSupply = usds.totalSupply();
    mathint susdsTotalSupply = susds.totalSupply();

    // Correct vow set
    require vow != currentContract && vow != usdsJoin;
    // Happening in initialize
    require vat.can(currentContract, usdsJoin) == 1;
    require usds.allowance(currentContract, susds) == max_uint256;
    require usds.allowance(currentContract, usdsJoin) == max_uint256;
    // Happening in init scripts
    require vat.wards(currentContract) == 1;
    // ERC20 correct behaviour
    require usdsTotalSupply >= usds.balanceOf(currentContract) + usds.balanceOf(susds);
    require susdsTotalSupply >= susds.balanceOf(currentContract);
    requireInvariant susdsBalance_greater_or_equal_than_totalAssets();
    // Correct behaviour sUSDS: it holds the USDS its supply is worth
    require usds.balanceOf(susds) >= susdsTotalSupply * susdsChi / RAY();
    // Correct behaviour usdsJoin
    require vat.dai(usdsJoin) >= usdsTotalSupply * RAY();
    // Convenience assumptions
    require assets * susdsChi <= max_uint256;
    require lossAssets * susdsChi <= max_uint256;
    require usdsTotalSupply + gainUsds <= max_uint256;
    require susdsTotalSupply + assets <= max_uint256;
    require vat.sin(vow) + gainUsds * RAY() <= max_uint256;
    require vat.vice() + gainUsds * RAY() <= max_uint256;
    require vat.debt() + gainUsds * RAY() <= max_uint256;
    require vat.dai(currentContract) + gainUsds * RAY() <= max_uint256;
    require vat.dai(usdsJoin) + gainUsds * RAY() <= max_uint256;
    require vat.dai(vow) + lossUsds * RAY() <= max_uint256;

    settle@withrevert(e, assets);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;
    bool revert3 = assets != 0 && totalSupply * chi > max_uint256;
    bool revert4 = assets > 0 && totalAssets == 0;
    bool revert5 = assets > 0 && gainUsds * RAY() > max_uint256;
    bool revert6 = assets > 0 && assets * RAY() > max_uint256;
    bool revert7 = assets > 0 && chi + gainChi > MAX_UINT192();
    bool revert8 = to_mathint(assets) == MIN_INT256();
    bool revert9 = assets < 0 && lossAssets > totalAssets;

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6 ||
                            revert7 || revert8 || revert9;
}

// Verify correct storage changes for non reverting transfer
rule transfer(address to, uint256 value) {
    env e;

    requireInvariant balanceSum_equals_totalSupply();

    address otherAddr;
    require otherAddr != e.msg.sender && otherAddr != to;

    mathint balanceOfSenderBefore = balanceOf(e.msg.sender);
    mathint balanceOfToBefore = balanceOf(to);
    mathint balanceOfOtherBefore = balanceOf(otherAddr);

    transfer(e, to, value);

    mathint balanceOfSenderAfter = balanceOf(e.msg.sender);
    mathint balanceOfToAfter = balanceOf(to);
    mathint balanceOfOtherAfter = balanceOf(otherAddr);

    assert e.msg.sender != to => balanceOfSenderAfter == balanceOfSenderBefore - value;
    assert e.msg.sender != to => balanceOfToAfter == balanceOfToBefore + value;
    assert e.msg.sender == to => balanceOfSenderAfter == balanceOfSenderBefore;
    assert balanceOfOtherAfter == balanceOfOtherBefore;
}

// Verify revert rules on transfer
rule transfer_revert(address to, uint256 value) {
    env e;

    mathint balanceOfSender = balanceOf(e.msg.sender);

    transfer@withrevert(e, to, value);

    bool revert1 = e.msg.value > 0;
    bool revert2 = to == 0 || to == currentContract;
    bool revert3 = balanceOfSender < to_mathint(value);

    assert lastReverted <=> revert1 || revert2 || revert3;
}

// Verify correct storage changes for non reverting transferFrom
rule transferFrom(address from, address to, uint256 value) {
    env e;

    requireInvariant balanceSum_equals_totalSupply();

    address otherAddr;
    require otherAddr != from && otherAddr != to;
    address otherAddr2; address otherAddr3;
    require otherAddr2 != from || otherAddr3 != e.msg.sender;

    mathint balanceOfFromBefore = balanceOf(from);
    mathint balanceOfToBefore = balanceOf(to);
    mathint balanceOfOtherBefore = balanceOf(otherAddr);
    mathint allowanceFromSenderBefore = allowance(from, e.msg.sender);
    mathint allowanceOtherBefore = allowance(otherAddr2, otherAddr3);

    transferFrom(e, from, to, value);

    mathint balanceOfFromAfter = balanceOf(from);
    mathint balanceOfToAfter = balanceOf(to);
    mathint balanceOfOtherAfter = balanceOf(otherAddr);
    mathint allowanceFromSenderAfter = allowance(from, e.msg.sender);
    mathint allowanceOtherAfter = allowance(otherAddr2, otherAddr3);

    assert from != to => balanceOfFromAfter == balanceOfFromBefore - value;
    assert from != to => balanceOfToAfter == balanceOfToBefore + value;
    assert from == to => balanceOfFromAfter == balanceOfFromBefore;
    assert balanceOfOtherAfter == balanceOfOtherBefore;
    assert e.msg.sender != from && allowanceFromSenderBefore != max_uint256 => allowanceFromSenderAfter == allowanceFromSenderBefore - value;
    assert e.msg.sender == from => allowanceFromSenderAfter == allowanceFromSenderBefore;
    assert allowanceFromSenderBefore == max_uint256 => allowanceFromSenderAfter == allowanceFromSenderBefore;
    assert allowanceOtherAfter == allowanceOtherBefore;
}

// Verify revert rules on transferFrom
rule transferFrom_revert(address from, address to, uint256 value) {
    env e;

    mathint balanceOfFrom = balanceOf(from);
    mathint allowanceFromSender = allowance(from, e.msg.sender);

    transferFrom@withrevert(e, from, to, value);

    bool revert1 = e.msg.value > 0;
    bool revert2 = to == 0 || to == currentContract;
    bool revert3 = balanceOfFrom < to_mathint(value);
    bool revert4 = allowanceFromSender < to_mathint(value) && e.msg.sender != from;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4;
}

// Verify correct storage changes for non reverting approve
rule approve(address spender, uint256 value) {
    env e;

    address otherAddr; address otherAddr2;
    require otherAddr != e.msg.sender || otherAddr2 != spender;

    mathint allowanceOtherBefore = allowance(otherAddr, otherAddr2);

    approve(e, spender, value);

    mathint allowanceSenderSpenderAfter = allowance(e.msg.sender, spender);
    mathint allowanceOtherAfter = allowance(otherAddr, otherAddr2);

    assert allowanceSenderSpenderAfter == to_mathint(value);
    assert allowanceOtherAfter == allowanceOtherBefore;
}

// Verify revert rules on approve
rule approve_revert(address spender, uint256 value) {
    env e;

    approve@withrevert(e, spender, value);

    bool revert1 = e.msg.value > 0;

    assert lastReverted <=> revert1;
}

// Verify correct behaviour of asset getter
rule asset() {
    env e;

    address asset = asset(e);

    assert asset == susds();
}

// Verify correct behaviour of totalAssets getter
rule totalAssets() {
    env e;

    mathint totalAssetsCalc = defTotalAssets();

    mathint totalAssets = totalAssets(e);

    assert totalAssets == totalAssetsCalc;
}

// Verify correct behaviour of convertToShares getter
rule convertToShares(uint256 assets) {
    env e;

    mathint sharesCalc = defConvertToShares(assets);

    mathint shares = convertToShares(e, assets);

    assert shares == sharesCalc;
}

// Verify correct behaviour of convertToAssets getter
rule convertToAssets(uint256 shares) {
    env e;

    mathint assetsCalc = defConvertToAssets(shares);

    mathint assets = convertToAssets(e, shares);

    assert assets == assetsCalc;
}

// Verify correct behaviour of maxDeposit getter
rule maxDeposit(address anyAddr) {
    env e;

    mathint maxDeposit = maxDeposit(e, anyAddr);

    assert maxDeposit == 0;
}

// Verify correct storage changes for non reverting deposit
rule deposit(uint256 assets, address receiver) {
    env e;

    require e.msg.sender != currentContract;

    address otherAddr;
    require otherAddr != receiver;

    mathint totalSupplyBefore = totalSupply();
    mathint balanceOfReceiverBefore = balanceOf(receiver);
    mathint balanceOfOtherBefore = balanceOf(otherAddr);
    mathint susdsBalanceOfSrUsdsBefore = susds.balanceOf(currentContract);
    mathint susdsBalanceOfSenderBefore = susds.balanceOf(e.msg.sender);

    mathint sharesCalc = defConvertToShares(assets);

    // ERC20 correct behaviour
    require totalSupplyBefore >= balanceOfReceiverBefore + balanceOfOtherBefore;
    require susds.totalSupply() >= susdsBalanceOfSrUsdsBefore + susdsBalanceOfSenderBefore;

    mathint shares = deposit(e, assets, receiver);

    mathint totalSupplyAfter = totalSupply();
    mathint balanceOfReceiverAfter = balanceOf(receiver);
    mathint balanceOfOtherAfter = balanceOf(otherAddr);
    mathint susdsBalanceOfSrUsdsAfter = susds.balanceOf(currentContract);
    mathint susdsBalanceOfSenderAfter = susds.balanceOf(e.msg.sender);

    assert shares == sharesCalc;
    assert totalSupplyAfter == totalSupplyBefore + shares;
    assert balanceOfReceiverAfter == balanceOfReceiverBefore + shares;
    assert balanceOfOtherAfter == balanceOfOtherBefore;
    assert susdsBalanceOfSrUsdsAfter == susdsBalanceOfSrUsdsBefore + assets;
    assert susdsBalanceOfSenderAfter == susdsBalanceOfSenderBefore - assets;
}

// Verify revert rules on deposit
rule deposit_revert(uint256 assets, address receiver) {
    env e;

    require e.msg.sender != currentContract;

    mathint wardsSender = wards(e.msg.sender);

    mathint chi = chi();
    mathint totalSupply = totalSupply();

    mathint sharesCalc = defConvertToShares(assets);

    // ERC20 correct behaviour
    require susds.totalSupply() >= susds.balanceOf(currentContract) + susds.balanceOf(e.msg.sender);
    // Sender assumptions
    require susds.allowance(e.msg.sender, currentContract) >= assets;
    require susds.balanceOf(e.msg.sender) >= assets;

    deposit@withrevert(e, assets, receiver);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;
    bool revert3 = assets * RAY() > max_uint256;
    bool revert4 = chi == 0;
    bool revert5 = receiver == 0 || receiver == currentContract;
    bool revert6 = totalSupply + sharesCalc > max_uint256;

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6;
}

// Verify correct behaviour of maxRedeem getter
rule maxRedeem(address anyAddr) {
    env e;

    mathint maxRedeem = maxRedeem(e, anyAddr);

    assert maxRedeem == 0;
}

// Verify correct storage changes for non reverting redeem
rule redeem(uint256 shares, address receiver, address owner) {
    env e;

    address otherAddr;
    require otherAddr != owner;
    address otherAddr2; address otherAddr3;
    require otherAddr2 != owner || otherAddr3 != e.msg.sender;

    mathint totalSupplyBefore = totalSupply();
    mathint balanceOfOwnerBefore = balanceOf(owner);
    mathint balanceOfOtherBefore = balanceOf(otherAddr);
    mathint allowanceOwnerSenderBefore = allowance(owner, e.msg.sender);
    mathint allowanceOtherBefore = allowance(otherAddr2, otherAddr3);
    mathint susdsBalanceOfSrUsdsBefore = susds.balanceOf(currentContract);
    mathint susdsBalanceOfReceiverBefore = susds.balanceOf(receiver);

    mathint assetsCalc = defConvertToAssets(shares);

    // ERC20 correct behaviour
    require totalSupplyBefore >= balanceOfOwnerBefore + balanceOfOtherBefore;
    require susds.totalSupply() >= susdsBalanceOfSrUsdsBefore + susdsBalanceOfReceiverBefore;

    mathint assets = redeem(e, shares, receiver, owner);

    mathint totalSupplyAfter = totalSupply();
    mathint balanceOfOwnerAfter = balanceOf(owner);
    mathint balanceOfOtherAfter = balanceOf(otherAddr);
    mathint allowanceOwnerSenderAfter = allowance(owner, e.msg.sender);
    mathint allowanceOtherAfter = allowance(otherAddr2, otherAddr3);
    mathint susdsBalanceOfSrUsdsAfter = susds.balanceOf(currentContract);
    mathint susdsBalanceOfReceiverAfter = susds.balanceOf(receiver);

    assert assets == assetsCalc;
    assert totalSupplyAfter == totalSupplyBefore - shares;
    assert balanceOfOwnerAfter == balanceOfOwnerBefore - shares;
    assert balanceOfOtherAfter == balanceOfOtherBefore;
    assert e.msg.sender != owner && allowanceOwnerSenderBefore != max_uint256 => allowanceOwnerSenderAfter == allowanceOwnerSenderBefore - shares;
    assert e.msg.sender == owner => allowanceOwnerSenderAfter == allowanceOwnerSenderBefore;
    assert allowanceOwnerSenderBefore == max_uint256 => allowanceOwnerSenderAfter == allowanceOwnerSenderBefore;
    assert allowanceOtherAfter == allowanceOtherBefore;
    assert receiver != currentContract => susdsBalanceOfReceiverAfter == susdsBalanceOfReceiverBefore + assetsCalc;
    assert receiver != currentContract => susdsBalanceOfSrUsdsAfter == susdsBalanceOfSrUsdsBefore - assetsCalc;
    assert receiver == currentContract => susdsBalanceOfSrUsdsAfter == susdsBalanceOfSrUsdsBefore;
}

// Verify revert rules on redeem
rule redeem_revert(uint256 shares, address receiver, address owner) {
    env e;

    mathint wardsSender = wards(e.msg.sender);

    mathint chi = chi();
    mathint totalSupply = totalSupply();
    mathint balanceOfOwner = balanceOf(owner);
    mathint allowanceOwnerSender = allowance(owner, e.msg.sender);

    // ERC20 correct behaviour
    require totalSupply >= balanceOfOwner;
    require susds.totalSupply() >= susds.balanceOf(currentContract) + susds.balanceOf(receiver);
    requireInvariant susdsBalance_greater_or_equal_than_totalAssets();

    redeem@withrevert(e, shares, receiver, owner);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;
    bool revert3 = shares * chi > max_uint256;
    bool revert4 = balanceOfOwner < to_mathint(shares);
    bool revert5 = owner != e.msg.sender && allowanceOwnerSender < to_mathint(shares);
    bool revert6 = receiver == 0 || receiver == susds;

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4 || revert5 || revert6;
}

// Verify correct storage changes for non reverting permit
rule permitVRS(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
    env e;

    address otherAddr; address otherAddr2;
    require otherAddr != owner || otherAddr2 != spender;
    address otherAddr3;
    require otherAddr3 != owner;

    mathint allowanceOtherBefore = allowance(otherAddr, otherAddr2);
    mathint noncesOwnerBefore = nonces(owner);
    mathint noncesOtherBefore = nonces(otherAddr3);

    permit(e, owner, spender, value, deadline, v, r, s);

    mathint allowanceOwnerSpenderAfter = allowance(owner, spender);
    mathint allowanceOtherAfter = allowance(otherAddr, otherAddr2);
    mathint noncesOwnerAfter = nonces(owner);
    mathint noncesOtherAfter = nonces(otherAddr3);

    assert allowanceOwnerSpenderAfter == to_mathint(value);
    assert allowanceOtherAfter == allowanceOtherBefore;
    assert noncesOwnerBefore < max_uint256 => noncesOwnerAfter == noncesOwnerBefore + 1;
    assert noncesOwnerBefore == max_uint256 => noncesOwnerAfter == 0;
    assert noncesOtherAfter == noncesOtherBefore;
}

// Verify revert rules on permit
rule permitVRS_revert(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
    env e;

    bytes32 digest = aux.computeDigestForToken(
                        DOMAIN_SEPARATOR(),
                        PERMIT_TYPEHASH(),
                        owner,
                        spender,
                        value,
                        nonces(owner),
                        deadline
                    );
    address ownerRecover = aux.call_ecrecover(digest, v, r, s);
    bytes32 returnedSig = owner == signer ? signer.isValidSignature(e, digest, aux.VRSToSignature(v, r, s)) : to_bytes32(0);

    permit@withrevert(e, owner, spender, value, deadline, v, r, s);

    bool revert1 = e.msg.value > 0;
    bool revert2 = e.block.timestamp > deadline;
    bool revert3 = owner == 0;
    bool revert4 = owner != ownerRecover && returnedSig != to_bytes32(0x1626ba7e00000000000000000000000000000000000000000000000000000000);

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4;
}

// Verify correct storage changes for non reverting permit
rule permitSignature(address owner, address spender, uint256 value, uint256 deadline, bytes signature) {
    env e;

    address otherAddr; address otherAddr2;
    require otherAddr != owner || otherAddr2 != spender;
    address otherAddr3;
    require otherAddr3 != owner;

    mathint allowanceOtherBefore = allowance(otherAddr, otherAddr2);
    mathint noncesOwnerBefore = nonces(owner);
    mathint noncesOtherBefore = nonces(otherAddr3);

    permit(e, owner, spender, value, deadline, signature);

    mathint allowanceOwnerSpenderAfter = allowance(owner, spender);
    mathint allowanceOtherAfter = allowance(otherAddr, otherAddr2);
    mathint noncesOwnerAfter = nonces(owner);
    mathint noncesOtherAfter = nonces(otherAddr3);

    assert allowanceOwnerSpenderAfter == to_mathint(value);
    assert allowanceOtherAfter == allowanceOtherBefore;
    assert noncesOwnerBefore < max_uint256 => noncesOwnerAfter == noncesOwnerBefore + 1;
    assert noncesOwnerBefore == max_uint256 => noncesOwnerAfter == 0;
    assert noncesOtherAfter == noncesOtherBefore;
}

// Verify revert rules on permit
rule permitSignature_revert(address owner, address spender, uint256 value, uint256 deadline, bytes signature) {
    env e;

    bytes32 digest = aux.computeDigestForToken(
                        DOMAIN_SEPARATOR(),
                        PERMIT_TYPEHASH(),
                        owner,
                        spender,
                        value,
                        nonces(owner),
                        deadline
                    );
    uint8 v; bytes32 r; bytes32 s;
    v, r, s = aux.signatureToVRS(signature);
    address null_address = 0;
    address ownerRecover = aux.size(signature) == 65 ? aux.call_ecrecover(digest, v, r, s) : null_address;
    bytes32 returnedSig = owner == signer ? signer.isValidSignature(e, digest, signature) : to_bytes32(0);

    permit@withrevert(e, owner, spender, value, deadline, signature);

    bool revert1 = e.msg.value > 0;
    bool revert2 = e.block.timestamp > deadline;
    bool revert3 = owner == 0;
    bool revert4 = owner != ownerRecover && returnedSig != to_bytes32(0x1626ba7e00000000000000000000000000000000000000000000000000000000);

    assert lastReverted <=> revert1 || revert2 || revert3 ||
                            revert4;
}
