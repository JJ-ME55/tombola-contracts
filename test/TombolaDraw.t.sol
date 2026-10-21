// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DrandBeacon} from "../src/DrandBeacon.sol";
import {TombolaDraw} from "../src/TombolaDraw.sol";
import {TombolaSplitter, IPonsFeeEscrow, ITombolaDrawPots} from "../src/TombolaSplitter.sol";

/// A Pons fee escrow stand-in: holds ETH per recipient, pays it out on claim().
contract FakeEscrow is IPonsFeeEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address to) external payable {
        balanceOf[to] += msg.value;
    }

    function claim() external returns (uint256 amt) {
        amt = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok);
    }
}

/// An escrow whose claim() always reverts although it reports a balance.
contract RevertingEscrow is IPonsFeeEscrow {
    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function claim() external pure returns (uint256) {
        revert("paused");
    }
}

contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract ReentrantWinner {
    TombolaDraw public draw;
    uint256 public hits;

    receive() external payable {
        hits++;
        if (hits == 1) {
            // try to claim during the payout: must fail (nonReentrant) without breaking the payout
            try draw.claim(address(this)) {} catch {}
        }
    }
}

/// Builds the same sorted-pair Merkle tree the keeper publishes: leaves (account, cumulativeBefore, weight).
library Tree {
    function leaf(address a, uint256 cum, uint256 w) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, cum, w))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// root and the proof for leaf `index`, for a list of leaves (padded by duplicating the last)
    function build(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32 root, bytes32[] memory proof) {
        uint256 n = leaves.length;
        uint256 depth = 0;
        while ((1 << depth) < n) depth++;
        bytes32[] memory level = new bytes32[](1 << depth);
        for (uint256 i = 0; i < level.length; i++) level[i] = leaves[i < n ? i : n - 1];
        proof = new bytes32[](depth);
        uint256 pos = index;
        for (uint256 d = 0; d < depth; d++) {
            proof[d] = level[pos ^ 1];
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i = 0; i < next.length; i++) next[i] = hashPair(level[2 * i], level[2 * i + 1]);
            level = next;
            pos /= 2;
        }
        root = level[0];
    }
}

contract TombolaDrawTest is Test {
    DrandBeacon beacon;
    TombolaDraw draw;
    TombolaSplitter splitter;
    FakeEscrow escrow;
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address team = makeAddr("team");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint64 ROUND;
    bytes SIG;

    function setUp() public {
        string memory json = vm.readFile("test/fixtures/evmnet.json");
        ROUND = uint64(vm.parseJsonUint(json, ".rounds[0].round"));
        SIG = vm.parseJsonBytes(json, ".rounds[0].signature");
        beacon = new DrandBeacon();
        escrow = new FakeEscrow();
        // the splitter needs the draw and the draw needs the splitter: predict the splitter's address
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        draw = new TombolaDraw(beacon, keeper, guardian, predicted);
        splitter = new TombolaSplitter(ITombolaDrawPots(address(draw)), team, escrow);
        assertEq(address(splitter), predicted);
        // the chain sits 20 minutes before the fixture round, so a commit at "now" is allowed
        vm.warp(beacon.roundTime(ROUND) - 20 minutes);
    }

    // ------------------------------------------------------------------ splitter
    function test_harvestSplitsEscrowFees() public {
        escrow.credit{value: 3 ether}(address(splitter));
        splitter.harvest();
        assertEq(draw.potRegular(), 3 ether * splitter.POT_BPS() / 10_000);
        assertEq(draw.potMega(), 3 ether * splitter.MEGA_BPS() / 10_000);
        assertEq(team.balance, 3 ether - 3 ether * splitter.POT_BPS() / 10_000 - 3 ether * splitter.MEGA_BPS() / 10_000);
        assertEq(address(splitter).balance, 0, "nothing stays in the splitter");
        assertTrue(draw.solvent());
    }

    function test_harvestSplitsWhatIsHereWhenTheEscrowClaimReverts() public {
        RevertingEscrow bad = new RevertingEscrow();
        TombolaSplitter s2 = new TombolaSplitter(ITombolaDrawPots(address(draw)), team, IPonsFeeEscrow(address(bad)));
        vm.deal(address(s2), 1 ether);
        s2.harvest();
        assertEq(draw.potRegular(), 1 ether * splitter.POT_BPS() / 10_000);
        assertEq(address(s2).balance, 0);
    }

    function test_harvestWithNothingIsANoop() public {
        splitter.harvest();
        assertEq(draw.potRegular(), 0);
    }

    function test_splitterSharesSumTo100() public view {
        assertEq(splitter.POT_BPS() + splitter.MEGA_BPS() + splitter.TEAM_BPS(), 10_000);
    }

    function testFuzz_splitterConservesEveryWei(uint96 amt) public {
        vm.assume(amt > 0);
        vm.deal(address(this), amt);
        escrow.credit{value: amt}(address(splitter));
        splitter.harvest();
        assertEq(draw.potRegular() + draw.potMega() + team.balance, amt);
    }

    // ------------------------------------------------------------------ the draw
    function _fund(uint256 amt) internal {
        vm.deal(address(this), amt);
        draw.fundRegular{value: amt}();
    }

    /// three wallets with weights 100, 250, 50 (cumulative 0, 100, 350; total 400)
    function _list() internal view returns (address[3] memory a, uint256[3] memory cum, uint256[3] memory w) {
        a = [alice, bob, carol];
        w = [uint256(100e18), 250e18, 50e18];
        cum = [uint256(0), 100e18, 350e18];
    }

    function _leaves() internal view returns (bytes32[] memory leaves) {
        (address[3] memory a, uint256[3] memory cum, uint256[3] memory w) = _list();
        leaves = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) leaves[i] = Tree.leaf(a[i], cum[i], w[i]);
    }

    function _root() internal view returns (bytes32 root) {
        (root,) = Tree.build(_leaves(), 0);
    }

    /// the keeper pins the honest three-wallet list at "now" and commits amt to the fixture round
    function _commit(uint256 amt) internal returns (uint256 id) {
        vm.prank(keeper);
        id = draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, amt, _root(), 400e18);
    }

    /// a one-wallet list: the wallet holds the whole weight so it must win
    function _commitSolo(address who) internal returns (uint256 id, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = Tree.leaf(who, 0, 1e18);
        bytes32 root;
        (root, proof) = Tree.build(leaves, 0);
        vm.prank(keeper);
        id = draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, root, 1e18);
    }

    function _winnerIndex(uint256 id) internal view returns (uint256 idx, uint256 target) {
        uint256 word = uint256(keccak256(abi.encode(keccak256(SIG), id)));
        target = word % 400e18;
        (, uint256[3] memory cum, uint256[3] memory w) = _list();
        for (idx = 0; idx < 3; idx++) if (target >= cum[idx] && target < cum[idx] + w[idx]) return (idx, target);
    }

    function test_commitSettlePaysTheProvenWinner() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        assertEq(draw.reserved(), 1 ether);
        assertEq(draw.potRegular(), 0);
        TombolaDraw.Draw memory pinned = draw.getDraw(id);
        assertEq(pinned.root, _root(), "the list is pinned at commit");
        assertEq(pinned.totalWeight, 400e18);
        vm.warp(beacon.roundTime(ROUND) + 1);

        (uint256 idx,) = _winnerIndex(id);
        (, bytes32[] memory proof) = Tree.build(_leaves(), idx);
        (address[3] memory a, uint256[3] memory cum, uint256[3] memory w) = _list();
        uint256 before = a[idx].balance;
        vm.prank(keeper);
        draw.settle(id, SIG, a[idx], cum[idx], w[idx], proof);
        assertEq(a[idx].balance, before + 1 ether, "the winner is paid");
        TombolaDraw.Draw memory d = draw.getDraw(id);
        assertEq(d.winner, a[idx]);
        assertTrue(d.settled);
        assertEq(draw.reserved(), 0);
        assertEq(draw.activeDraw(TombolaDraw.Track.Regular), 0);
        assertEq(beacon.randomness(ROUND), keccak256(SIG), "the round is proven on chain");
        assertTrue(draw.solvent());
    }

    /// the audit's High: with totalWeight pinned at commit, the keeper can no longer pick a listed non-winner
    /// after the round by choosing the modulus
    function test_settleRefusesTheWrongWinner() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        (uint256 idx,) = _winnerIndex(id);
        uint256 other = (idx + 1) % 3;
        (, bytes32[] memory proof) = Tree.build(_leaves(), other);
        (address[3] memory a, uint256[3] memory cum, uint256[3] memory w) = _list();
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.BadWinner.selector);
        draw.settle(id, SIG, a[other], cum[other], w[other], proof);
    }

    function test_settleRefusesALeafNotInTheList() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        (uint256 idx,) = _winnerIndex(id);
        (, bytes32[] memory proof) = Tree.build(_leaves(), idx);
        (, uint256[3] memory cum, uint256[3] memory w) = _list();
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.BadProof.selector);
        draw.settle(id, SIG, makeAddr("intruder"), cum[idx], w[idx], proof);
    }

    function test_settleRefusesAWeightOutsideTheTotal() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        (, bytes32[] memory proof) = Tree.build(_leaves(), 0);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.BadWeights.selector);
        draw.settle(id, SIG, alice, 0, 500e18, proof); // weight > the pinned total
    }

    function test_settleRefusesABadSignature() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        bytes memory bad = SIG;
        bad[5] ^= 0x01;
        (, bytes32[] memory proof) = Tree.build(_leaves(), 0);
        vm.prank(keeper);
        vm.expectRevert(DrandBeacon.InvalidSignature.selector);
        draw.settle(id, bad, alice, 0, 100e18, proof);
    }

    function test_settleRefusesTheContractsAsWinner() public {
        _fund(2 ether);
        (uint256 id, bytes32[] memory proof) = _commitSolo(address(splitter));
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.BadWinner.selector);
        draw.settle(id, SIG, address(splitter), 0, 1e18, proof);
        vm.prank(guardian);
        vm.expectRevert(TombolaDraw.TooEarly.selector); // the round is public: nobody cancels now
        draw.cancel(id);
    }

    function test_commitRefusesARoundTooEarlyOrAlreadyKnown() public {
        _fund(1 ether);
        uint64 soon = beacon.roundAt(block.timestamp + 5 minutes);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.RoundTooEarly.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), soon, 1 ether, _root(), 400e18);
        // ten minutes after the snapshot but not after the commit block
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.RoundTooEarly.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp - 20 minutes), soon, 1 ether, _root(), 400e18);
        // a round whose randomness is already on chain can't be committed to either
        vm.store(address(beacon), keccak256(abi.encode(uint256(ROUND), uint256(0))), bytes32(uint256(1)));
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.RoundTooEarly.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, _root(), 400e18);
    }

    function test_commitRefusesARoundFarInTheFuture() public {
        _fund(1 ether);
        uint64 far = beacon.roundAt(block.timestamp + 2 days);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.RoundTooLate.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), far, 1 ether, _root(), 400e18);
        uint64 mistaken = uint64(block.timestamp); // a unix time passed as a round number
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.RoundTooLate.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), mistaken, 1 ether, _root(), 400e18);
    }

    function test_commitRefusesAStaleOrFutureSnapshot() public {
        _fund(1 ether);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.WrongStage.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp + 1), ROUND, 1 ether, _root(), 400e18);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.WrongStage.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp - 31 minutes), ROUND, 1 ether, _root(), 400e18);
        vm.prank(keeper);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp - 10 minutes), ROUND, 1 ether, _root(), 400e18);
    }

    function test_commitRefusesAnInconsistentListOrOverspend() public {
        _fund(1 ether);
        bytes32 empty = draw.EMPTY_ROOT();
        bytes32 honest = _root();
        vm.startPrank(keeper);
        vm.expectRevert(TombolaDraw.BadWeights.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, honest, 0);
        vm.expectRevert(TombolaDraw.BadWeights.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, empty, 400e18);
        vm.expectRevert(TombolaDraw.BadWeights.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, bytes32(0), 400e18);
        vm.expectRevert(TombolaDraw.NotEnoughPot.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 2 ether, _root(), 400e18);
        vm.stopPrank();
    }

    function test_oneOpenDrawPerTrack() public {
        _fund(2 ether);
        _commit(1 ether);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.TrackBusy.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, _root(), 400e18);
    }

    function test_onlyTheKeeperCommitsButAnyoneSettles() public {
        _fund(1 ether);
        vm.expectRevert(TombolaDraw.NotKeeper.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, _root(), 400e18);
        uint256 id = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        (uint256 idx,) = _winnerIndex(id);
        (, bytes32[] memory proof) = Tree.build(_leaves(), idx);
        (address[3] memory a, uint256[3] memory cum, uint256[3] memory w) = _list();
        // a stranger settles with the public data: the keeper can't withhold a known result
        vm.prank(makeAddr("stranger"));
        draw.settle(id, SIG, a[idx], cum[idx], w[idx], proof);
        assertEq(draw.getDraw(id).winner, a[idx]);
    }

    function test_anyoneRollsOverAnEmptyDraw() public {
        _fund(1 ether);
        bytes32 empty = draw.EMPTY_ROOT();
        vm.prank(keeper);
        uint256 id = draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, empty, 0);
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(makeAddr("stranger"));
        draw.rollover(id, SIG);
        assertEq(draw.potRegular(), 1 ether);
    }

    function test_guardianCancelStopsAMinuteBeforeTheRound() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) - 30);
        vm.prank(guardian);
        vm.expectRevert(TombolaDraw.TooEarly.selector);
        draw.cancel(id);
        vm.warp(beacon.roundTime(ROUND) - 2 minutes);
        vm.prank(guardian);
        draw.cancel(id);
        assertTrue(draw.getDraw(id).cancelled);
    }

    function test_megaCreditExpiresBackToTheMegaPot() public {
        RejectsEth r = new RejectsEth();
        vm.deal(address(this), 1 ether);
        draw.fundMega{value: 1 ether}();
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = Tree.leaf(address(r), 0, 1e18);
        (bytes32 root, bytes32[] memory proof) = Tree.build(leaves, 0);
        vm.prank(keeper);
        uint256 id = draw.commit(TombolaDraw.Track.Mega, uint64(block.timestamp), ROUND, 1 ether, root, 1e18);
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(keeper);
        draw.settle(id, SIG, address(r), 0, 1e18, proof);
        assertEq(draw.unclaimedMega(address(r)), 1 ether);
        vm.warp(block.timestamp + 365 days);
        draw.expireCredit(address(r));
        assertEq(draw.potMega(), 1 ether);
        assertEq(draw.potRegular(), 0);
        assertTrue(draw.solvent());
    }

    function test_rolloverOnlyWhenNobodyWasEligible() public {
        _fund(1 ether);
        bytes32 empty = draw.EMPTY_ROOT();
        vm.prank(keeper);
        uint256 id = draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, empty, 0);
        vm.warp(beacon.roundTime(ROUND) + 1);
        (, bytes32[] memory proof) = Tree.build(_leaves(), 0);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.WrongStage.selector);
        draw.settle(id, SIG, alice, 0, 100e18, proof);
        vm.prank(keeper);
        draw.rollover(id, SIG);
        assertEq(draw.potRegular(), 1 ether);
        assertEq(draw.reserved(), 0);
        assertTrue(draw.getDraw(id).settled);
        assertEq(draw.getDraw(id).winner, address(0));

        // a draw with an eligible list can't be rolled over once the winner is known
        vm.warp(beacon.roundTime(ROUND) - 20 minutes);
        vm.store(address(beacon), keccak256(abi.encode(uint256(ROUND), uint256(0))), bytes32(0)); // forget the proof
        uint256 id2 = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.WrongStage.selector);
        draw.rollover(id2, SIG);
    }

    function test_guardianCancelsOnlyBeforeTheRoundAndAnyoneAfterSevenDays() public {
        _fund(1 ether);
        uint256 id = _commit(1 ether);
        vm.expectRevert(TombolaDraw.NotGuardian.selector);
        draw.cancel(id);
        vm.prank(guardian);
        draw.cancel(id);
        assertEq(draw.potRegular(), 1 ether);
        assertTrue(draw.getDraw(id).cancelled);

        uint256 id2 = _commit(1 ether);
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(guardian);
        vm.expectRevert(TombolaDraw.TooEarly.selector); // the outcome is public: no veto
        draw.cancel(id2);
        vm.warp(beacon.roundTime(ROUND) + 7 days);
        draw.cancel(id2); // anyone, once abandoned
        assertEq(draw.potRegular(), 1 ether);
    }

    function test_guardianRotatesTheKeeperAtAnyTime() public {
        address next = makeAddr("next keeper");
        vm.expectRevert(TombolaDraw.NotGuardian.selector);
        draw.setKeeper(next);
        _fund(1 ether);
        _commit(1 ether); // an open draw doesn't block the rotation: a leaked key can't hold it off
        vm.prank(guardian);
        draw.setKeeper(next);
        assertEq(draw.keeper(), next);
        vm.prank(guardian);
        draw.cancel(0);
        vm.prank(keeper);
        vm.expectRevert(TombolaDraw.NotKeeper.selector);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, _root(), 400e18);
        vm.prank(next);
        draw.commit(TombolaDraw.Track.Regular, uint64(block.timestamp), ROUND, 1 ether, _root(), 400e18);
    }

    function test_failedPayoutIsCreditedAndExpiresBackToThePot() public {
        RejectsEth r = new RejectsEth();
        _fund(1 ether);
        (uint256 id, bytes32[] memory proof) = _commitSolo(address(r));
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(keeper);
        draw.settle(id, SIG, address(r), 0, 1e18, proof);
        assertEq(draw.unclaimed(address(r)), 1 ether);
        assertTrue(draw.solvent());
        vm.expectRevert(TombolaDraw.SendFailed.selector);
        draw.claim(address(r));
        vm.expectRevert(TombolaDraw.TooEarly.selector);
        draw.expireCredit(address(r));
        vm.warp(block.timestamp + 365 days);
        draw.expireCredit(address(r));
        assertEq(draw.unclaimed(address(r)), 0);
        assertEq(draw.potRegular(), 1 ether);
        assertTrue(draw.solvent());
    }

    function test_creditedContractCanRedirectItsPrize() public {
        Redirector r = new Redirector();
        _fund(1 ether);
        (uint256 id, bytes32[] memory proof) = _commitSolo(address(r));
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(keeper);
        draw.settle(id, SIG, address(r), 0, 1e18, proof);
        assertEq(draw.unclaimed(address(r)), 1 ether, "a receiver that needs more than the stipend is credited");
        address home = makeAddr("home");
        r.collect(draw, home);
        assertEq(home.balance, 1 ether);
        assertEq(draw.unclaimedTotal(), 0);
        assertTrue(draw.solvent());
    }

    function test_reentrantWinnerCantReenter() public {
        ReentrantWinner w = new ReentrantWinner();
        vm.store(address(w), bytes32(uint256(0)), bytes32(uint256(uint160(address(draw)))));
        _fund(1 ether);
        (uint256 id, bytes32[] memory proof) = _commitSolo(address(w));
        vm.warp(beacon.roundTime(ROUND) + 1);
        vm.prank(keeper);
        draw.settle(id, SIG, address(w), 0, 1e18, proof);
        assertEq(address(w).balance, 1 ether);
        assertTrue(draw.solvent());
    }

    function test_weightForMatchesTheOriginalRule() public view {
        uint256 t = 200 days;
        assertEq(draw.weightFor(9_999e18, 0, t), 0, "below the minimum");
        assertEq(draw.weightFor(10_000e18, t - 29 minutes, t), 0, "held under 30 minutes");
        assertEq(draw.weightFor(10_000e18, t - 30 minutes, t), 10_000e18 * (1e18 + uint256(30 minutes) * 2e18 / uint256(72 hours)) / 1e18);
        assertEq(draw.weightFor(10_000e18, t - 36 hours, t), 20_000e18, "2x at half way");
        assertEq(draw.weightFor(10_000e18, t - 72 hours, t), 30_000e18, "3x at 72 h");
        assertEq(draw.weightFor(10_000e18, t - 100 days, t), 30_000e18, "capped at 3x");
    }

    function test_plainEthGoesToTheRegularPot() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(draw).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(draw.potRegular(), 1 ether);
    }

    receive() external payable {}
}

/// A winner whose receive() burns more than the payout stipend (so it is credited) and then collects via redirectCredit.
contract Redirector {
    uint256[] private _sink;

    receive() external payable {
        if (gasleft() < 60_000) { for (uint256 i = 0; i < 10; i++) _sink.push(i); } // needs more than PAYOUT_GAS
    }

    function collect(TombolaDraw draw, address to) external {
        draw.redirectCredit(to);
    }
}
