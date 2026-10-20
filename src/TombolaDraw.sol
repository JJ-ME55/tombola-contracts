// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DrandBeacon} from "./DrandBeacon.sol";

/// @title TombolaDraw
/// @notice Holds Tombola's two prize pots (regular and mega, in ETH) and the draw ledger for the Pons launch, where
///         the token is Pons' plain ERC-20 and eligibility can't be read on chain. The keeper commits each draw to
///         a FUTURE drand round before taking the snapshot, then settles it with the published snapshot's Merkle
///         root, the winner's leaf and drand's signature. The contract enforces what it can:
///           - the drand round was committed before anyone could know it (round time > snapshot + COMMIT_DELAY,
///             and later than the commit itself);
///           - the signature is drand's (the beacon verifies BLS on BN254) and the winner's index is
///             randomWord mod totalWeight over the list the keeper pinned by root;
///           - the winner is in that list with the weight the keeper claims (Merkle proof), and the selection index
///             falls inside the winner's cumulative weight range (the leaf carries the cumulative weight before it);
///           - prizes only ever go to settled winners; nothing else can move ETH out.
///         What it cannot enforce is that the pinned list is complete and the weights honest: anyone recomputes
///         that from Transfer logs (bot/pons/verify-draw.mjs, the site's Verify). A guardian may cancel a committed draw
///         before it settles. No owner, no upgrade, no withdraw.
contract TombolaDraw {
    enum Track {
        Regular,
        Mega
    }

    struct Draw {
        Track track;
        uint64 snapshotTime; // the snapshot is the chain state at the last block with timestamp <= snapshotTime
        uint64 drandRound; // committed before the snapshot's randomness existed
        uint128 amount; // the prize, reserved from the track's pot at commit
        bytes32 root; // Merkle root of the published snapshot (account, cumulativeBefore, weight)
        uint256 totalWeight; // sum of all weights in the pinned list
        uint256 randomWord; // keccak256(drand randomness, id)
        address winner; // address(0) until settled; rolled over if nobody was eligible
        bool settled;
        bool cancelled;
    }

    uint256 public constant COMMIT_DELAY = 10 minutes; // the drand round must be at least this far after the snapshot
    uint256 public constant ELIGIBLE_AFTER = 30 minutes;
    uint256 public constant FULL_MULTIPLIER_AFTER = 72 hours;
    uint256 public constant MIN_BALANCE = 10_000e18;
    uint256 public constant ABANDON_AFTER = 7 days; // a draw whose round never gets settled can be cancelled by anyone
    uint256 public constant PAYOUT_GAS = 50_000;

    DrandBeacon public immutable beacon;
    address public immutable keeper;
    address public immutable guardian;
    address public immutable splitter; // the only funder besides plain ETH gifts

    uint256 public potRegular;
    uint256 public potMega;
    uint256 public reserved; // committed, unsettled prizes
    uint256 public unclaimedTotal;
    mapping(address => uint256) public unclaimed;

    Draw[] private _draws;
    mapping(Track => uint256) public activeDraw; // id + 1 of the open draw on the track, 0 if none

    event Funded(Track track, uint256 amount);
    event Committed(uint256 indexed id, Track track, uint64 snapshotTime, uint64 drandRound, uint256 amount);
    event Settled(uint256 indexed id, address indexed winner, uint256 amount, bytes32 root, uint256 totalWeight, uint256 randomWord);
    event RolledOver(uint256 indexed id, bytes32 root);
    event Cancelled(uint256 indexed id);
    event PayoutCredited(address indexed to, uint256 amount);
    event Claimed(address indexed to, uint256 amount);

    error NotKeeper();
    error NotGuardian();
    error NotSplitter();
    error TrackBusy();
    error NoDraw();
    error WrongStage();
    error RoundTooEarly();
    error NotEnoughPot();
    error BadProof();
    error BadWinner();
    error BadWeights();
    error TooEarly();
    error SendFailed();
    error Reentered();

    uint256 private _lock;

    modifier nonReentrant() {
        if (_lock == 1) revert Reentered();
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor(DrandBeacon beacon_, address keeper_, address guardian_, address splitter_) {
        require(address(beacon_) != address(0) && keeper_ != address(0) && splitter_ != address(0), "zero");
        beacon = beacon_;
        keeper = keeper_;
        guardian = guardian_;
        splitter = splitter_;
    }

    // ------------------------------------------------------------------ pots
    function fundRegular() external payable {
        potRegular += msg.value;
        emit Funded(Track.Regular, msg.value);
    }

    function fundMega() external payable {
        potMega += msg.value;
        emit Funded(Track.Mega, msg.value);
    }

    /// plain ETH goes to the regular pot
    receive() external payable {
        potRegular += msg.value;
        emit Funded(Track.Regular, msg.value);
    }

    // ------------------------------------------------------------------ keeper
    /// @notice Open a draw: reserve `amount` from the track's pot and commit to `drandRound`, which must be
    ///         published only after snapshotTime + COMMIT_DELAY and after this block, so the randomness can't be
    ///         known when the snapshot is taken nor when the draw is committed. snapshotTime may not be in the future.
    function commit(Track track, uint64 snapshotTime, uint64 drandRound, uint256 amount) external returns (uint256 id) {
        if (msg.sender != keeper) revert NotKeeper();
        if (activeDraw[track] != 0) revert TrackBusy();
        if (snapshotTime > block.timestamp) revert WrongStage();
        uint256 roundTime = beacon.roundTime(drandRound);
        if (roundTime < uint256(snapshotTime) + COMMIT_DELAY) revert RoundTooEarly();
        if (roundTime <= block.timestamp) revert RoundTooEarly(); // the round must still be in the future
        if (beacon.randomness(drandRound) != bytes32(0)) revert RoundTooEarly(); // already known on chain
        uint256 pot = track == Track.Regular ? potRegular : potMega;
        if (amount == 0 || amount > pot || amount > type(uint128).max) revert NotEnoughPot();
        if (track == Track.Regular) potRegular -= amount;
        else potMega -= amount;
        reserved += amount;
        id = _draws.length;
        _draws.push(
            Draw({
                track: track,
                snapshotTime: snapshotTime,
                drandRound: drandRound,
                amount: uint128(amount),
                root: bytes32(0),
                totalWeight: 0,
                randomWord: 0,
                winner: address(0),
                settled: false,
                cancelled: false
            })
        );
        activeDraw[track] = id + 1;
        emit Committed(id, track, snapshotTime, drandRound, amount);
    }

    /// @notice Settle a draw with drand's signature for the committed round, the published snapshot's root and
    ///         total weight, and the winner's leaf: (winner, cumulativeBefore, weight) with its proof. The contract
    ///         checks the signature, derives the random word, checks the leaf is in the pinned list and that
    ///         randomWord mod totalWeight falls in [cumulativeBefore, cumulativeBefore + weight), then pays.
    function settle(
        uint256 id,
        bytes calldata drandSignature,
        bytes32 root,
        uint256 totalWeight,
        address winner,
        uint256 cumulativeBefore,
        uint256 weight,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        Draw storage d = _open(id);
        // prove() verifies the BLS signature itself and reverts InvalidSignature on a bad one; a round already
        // proven is a no-op, so the signature may be empty then
        bytes32 rnd = beacon.prove(d.drandRound, drandSignature);
        uint256 word = uint256(keccak256(abi.encode(rnd, id)));
        if (root == bytes32(0) || totalWeight == 0) revert BadWeights();
        if (weight == 0 || cumulativeBefore + weight > totalWeight) revert BadWeights();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(winner, cumulativeBefore, weight))));
        if (!_verify(proof, root, leaf)) revert BadProof();
        uint256 target = word % totalWeight;
        if (target < cumulativeBefore || target >= cumulativeBefore + weight) revert BadWinner();

        d.root = root;
        d.totalWeight = totalWeight;
        d.randomWord = word;
        d.winner = winner;
        d.settled = true;
        activeDraw[d.track] = 0;
        uint256 amount = d.amount;
        reserved -= amount;
        emit Settled(id, winner, amount, root, totalWeight, word);
        _pay(winner, amount);
    }

    /// @notice Nobody was eligible at the snapshot (the pinned list is empty): the pot goes back. The keeper pins
    ///         the (empty-list) root it published so the rollover is as verifiable as a win.
    function rollover(uint256 id, bytes calldata drandSignature, bytes32 root) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        Draw storage d = _open(id);
        // prove() verifies the BLS signature itself and reverts InvalidSignature on a bad one; a round already
        // proven is a no-op, so the signature may be empty then
        bytes32 rnd = beacon.prove(d.drandRound, drandSignature);
        d.root = root;
        d.randomWord = uint256(keccak256(abi.encode(rnd, id)));
        d.settled = true;
        activeDraw[d.track] = 0;
        _return(d);
        emit RolledOver(id, root);
    }

    // ------------------------------------------------------------------ guardian / anyone
    /// @notice The guardian may cancel a committed, unsettled draw (a bad snapshot the keeper hasn't settled). After
    ///         ABANDON_AFTER past the round's time anyone may, so a dead keeper can't lock a pot. The pot goes back.
    function cancel(uint256 id) external nonReentrant {
        Draw storage d = _open(id);
        bool late = block.timestamp >= beacon.roundTime(d.drandRound) + ABANDON_AFTER;
        if (msg.sender != guardian && !late) revert NotGuardian();
        d.cancelled = true;
        activeDraw[d.track] = 0;
        _return(d);
        emit Cancelled(id);
    }

    /// @notice A prize whose send failed is credited; the winner (or anyone, for them) claims it here.
    function claim(address to) external nonReentrant {
        uint256 amt = unclaimed[to];
        if (amt == 0) revert NoDraw();
        unclaimed[to] = 0;
        unclaimedTotal -= amt;
        (bool ok,) = payable(to).call{value: amt}("");
        if (!ok) revert SendFailed();
        emit Claimed(to, amt);
    }

    // ------------------------------------------------------------------ views
    function drawCount() external view returns (uint256) {
        return _draws.length;
    }

    function getDraw(uint256 id) external view returns (Draw memory) {
        if (id >= _draws.length) revert NoDraw();
        return _draws[id];
    }

    /// @notice The weight the keeper must give a wallet with `bal` held since `holdStart` at snapshot `t`: the
    ///         same rule the IMD design enforced on chain, published here so verifiers and the contract agree.
    function weightFor(uint256 bal, uint256 holdStart, uint256 t) external pure returns (uint256) {
        if (bal < MIN_BALANCE || holdStart > t || t - holdStart < ELIGIBLE_AFTER) return 0;
        uint256 held = t - holdStart;
        uint256 mult = held >= FULL_MULTIPLIER_AFTER ? 3e18 : 1e18 + held * 2e18 / FULL_MULTIPLIER_AFTER;
        return bal * mult / 1e18;
    }

    /// @notice Every wei here is a pot, a reserved prize or an unclaimed credit.
    function solvent() external view returns (bool) {
        return address(this).balance >= potRegular + potMega + reserved + unclaimedTotal;
    }

    // ------------------------------------------------------------------ internals
    function _open(uint256 id) internal view returns (Draw storage d) {
        if (id >= _draws.length) revert NoDraw();
        d = _draws[id];
        if (d.settled || d.cancelled) revert WrongStage();
    }

    function _return(Draw storage d) internal {
        uint256 amount = d.amount;
        reserved -= amount;
        if (d.track == Track.Regular) potRegular += amount;
        else potMega += amount;
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount, gas: PAYOUT_GAS}("");
        if (!ok) {
            unclaimed[to] += amount;
            unclaimedTotal += amount;
            emit PayoutCredited(to, amount);
        }
    }

    /// OpenZeppelin's sorted-pair Merkle verification, inlined (no library import to keep the dependency surface small)
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }
}
