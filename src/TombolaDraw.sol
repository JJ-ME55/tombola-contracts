// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DrandBeacon} from "./DrandBeacon.sol";

/// @title TombolaDraw
/// @notice Holds Tombola's two prize pots (regular and mega, in ETH) and the draw ledger for the Pons launch, where
///         the token is Pons' plain ERC-20 and eligibility can't be read on chain. The keeper takes the snapshot
///         first, then commits the draw: the list's Merkle root and total weight are pinned on chain together
///         with a FUTURE drand round, and only afterwards can the round be published. Settling supplies drand's
///         signature and the winner's leaf. The contract enforces what it can:
///           - the list (root and total weight) was pinned before the randomness existed: the round's time is at
///             least COMMIT_DELAY after both the snapshot and the commit block, and at most MAX_LEAD ahead;
///           - the snapshot is recent (at most MAX_SNAPSHOT_AGE before the commit), so the keeper can't pick a
///             historical holder set;
///           - the signature is drand's (the beacon verifies BLS on BN254) and the winner's index is
///             randomWord mod the pinned totalWeight;
///           - the winner is in the pinned list with the weight the keeper claimed (Merkle proof), and the
///             selection index falls inside the winner's cumulative range;
///           - a rollover (nobody eligible) is only possible when the pinned list was empty;
///           - prizes only ever go to settled winners; nothing else can move ETH out.
///         What it cannot enforce is that the pinned list is complete and the weights honest: anyone recomputes
///         that from Transfer logs (bot/pons/verify-draw.mjs, the site's Verify) in the window between the commit
///         and the round, and the guardian may cancel a committed draw in that window. After the round's time
///         nobody can cancel until ABANDON_AFTER has passed, so a known outcome can't be vetoed. No owner, no
///         upgrade, no withdraw; the guardian may rotate the keeper between draws.
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
        bytes32 root; // Merkle root of the published snapshot (account, cumulativeBefore, weight), pinned at commit
        uint256 totalWeight; // sum of all weights in the pinned list, pinned at commit (0: nobody eligible)
        uint256 randomWord; // keccak256(drand randomness, id), set at settle
        address winner; // address(0) until settled; stays so on a rollover
        bool settled;
        bool cancelled;
    }

    uint256 public constant COMMIT_DELAY = 10 minutes; // the round must be this far after both the snapshot and the commit
    uint256 public constant MAX_LEAD = 1 days; // and no further ahead than this, so the abandon path always opens
    uint256 public constant MAX_SNAPSHOT_AGE = 30 minutes; // a snapshot older than this at commit is refused
    uint256 public constant ELIGIBLE_AFTER = 30 minutes;
    uint256 public constant FULL_MULTIPLIER_AFTER = 72 hours;
    uint256 public constant MIN_BALANCE = 10_000e18;
    uint256 public constant ABANDON_AFTER = 7 days; // a draw whose round never gets settled can be cancelled by anyone
    uint256 public constant CREDIT_EXPIRY = 365 days; // an unclaimed prize older than this may be returned to the pot
    uint256 public constant PAYOUT_GAS = 50_000;
    bytes32 public constant EMPTY_ROOT = keccak256(""); // the root an empty list pins

    DrandBeacon public immutable beacon;
    address public immutable guardian;
    address public immutable splitter; // the only funder besides plain ETH gifts
    address public keeper; // the hot wallet; the guardian may replace it between draws

    uint256 public potRegular;
    uint256 public potMega;
    uint256 public reserved; // committed, unsettled prizes
    uint256 public unclaimedTotal;
    mapping(address => uint256) public unclaimed;
    mapping(address => uint256) public creditedAt; // when the credit was (last) made

    Draw[] private _draws;
    mapping(Track => uint256) public activeDraw; // id + 1 of the open draw on the track, 0 if none

    event Funded(Track track, uint256 amount);
    event Committed(uint256 indexed id, Track track, uint64 snapshotTime, uint64 drandRound, uint256 amount, bytes32 root, uint256 totalWeight);
    event Settled(uint256 indexed id, address indexed winner, uint256 amount, bytes32 root, uint256 totalWeight, uint256 randomWord);
    event RolledOver(uint256 indexed id, bytes32 root);
    event Cancelled(uint256 indexed id);
    event PayoutCredited(address indexed to, uint256 amount);
    event CreditRedirected(address indexed from, address indexed to, uint256 amount);
    event CreditExpired(address indexed from, uint256 amount);
    event Claimed(address indexed to, uint256 amount);
    event KeeperChanged(address indexed keeper);

    error NotKeeper();
    error NotGuardian();
    error TrackBusy();
    error NoDraw();
    error WrongStage();
    error RoundTooEarly();
    error RoundTooLate();
    error NotEnoughPot();
    error BadProof();
    error BadWinner();
    error BadWeights();
    error TooEarly();
    error SendFailed();
    error Reentered();
    error ZeroAddress();

    uint256 private _lock;

    modifier nonReentrant() {
        if (_lock == 1) revert Reentered();
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor(DrandBeacon beacon_, address keeper_, address guardian_, address splitter_) {
        if (address(beacon_) == address(0) || keeper_ == address(0) || guardian_ == address(0) || splitter_ == address(0)) revert ZeroAddress();
        beacon = beacon_;
        keeper = keeper_;
        guardian = guardian_;
        splitter = splitter_;
        emit KeeperChanged(keeper_);
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
    /// @notice Open a draw: pin the snapshot list taken at `snapshotTime` (its Merkle `root` and `totalWeight`),
    ///         reserve `amount` from the track's pot and commit to `drandRound`. The snapshot must be recent and
    ///         not in the future; the round must be published only after snapshotTime + COMMIT_DELAY and after
    ///         this block + COMMIT_DELAY, and no further ahead than MAX_LEAD. An empty list pins EMPTY_ROOT with
    ///         totalWeight 0 and can only be rolled over.
    function commit(Track track, uint64 snapshotTime, uint64 drandRound, uint256 amount, bytes32 root, uint256 totalWeight)
        external
        returns (uint256 id)
    {
        if (msg.sender != keeper) revert NotKeeper();
        if (activeDraw[track] != 0) revert TrackBusy();
        if (snapshotTime > block.timestamp || block.timestamp - snapshotTime > MAX_SNAPSHOT_AGE) revert WrongStage();
        uint256 roundTime = beacon.roundTime(drandRound);
        if (roundTime < uint256(snapshotTime) + COMMIT_DELAY) revert RoundTooEarly();
        if (roundTime < block.timestamp + COMMIT_DELAY) revert RoundTooEarly();
        if (roundTime > block.timestamp + MAX_LEAD) revert RoundTooLate();
        if (beacon.randomness(drandRound) != bytes32(0)) revert RoundTooEarly(); // already known on chain
        if (totalWeight == 0 ? root != EMPTY_ROOT : (root == bytes32(0) || root == EMPTY_ROOT)) revert BadWeights();
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
                root: root,
                totalWeight: totalWeight,
                randomWord: 0,
                winner: address(0),
                settled: false,
                cancelled: false
            })
        );
        activeDraw[track] = id + 1;
        emit Committed(id, track, snapshotTime, drandRound, amount, root, totalWeight);
    }

    /// @notice Settle a draw with drand's signature for the committed round and the winner's leaf:
    ///         (winner, cumulativeBefore, weight) with its proof against the pinned root. The contract checks the
    ///         signature, derives the random word, checks the leaf is in the pinned list and that
    ///         randomWord mod the pinned totalWeight falls in [cumulativeBefore, cumulativeBefore + weight), then pays.
    function settle(uint256 id, bytes calldata drandSignature, address winner, uint256 cumulativeBefore, uint256 weight, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (msg.sender != keeper) revert NotKeeper();
        Draw storage d = _open(id);
        if (d.totalWeight == 0) revert WrongStage(); // nobody was eligible: rollover
        if (winner == address(0) || winner == address(this) || winner == splitter) revert BadWinner();
        // prove() verifies the BLS signature itself and reverts InvalidSignature on a bad one; a round already
        // proven is a no-op, so the signature may be empty then
        bytes32 rnd = beacon.prove(d.drandRound, drandSignature);
        uint256 word = uint256(keccak256(abi.encode(rnd, id)));
        uint256 totalWeight = d.totalWeight;
        if (weight == 0 || cumulativeBefore + weight > totalWeight) revert BadWeights();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(winner, cumulativeBefore, weight))));
        if (!_verify(proof, d.root, leaf)) revert BadProof();
        uint256 target = word % totalWeight;
        if (target < cumulativeBefore || target >= cumulativeBefore + weight) revert BadWinner();

        d.randomWord = word;
        d.winner = winner;
        d.settled = true;
        activeDraw[d.track] = 0;
        uint256 amount = d.amount;
        reserved -= amount;
        emit Settled(id, winner, amount, d.root, totalWeight, word);
        _pay(winner, amount);
    }

    /// @notice Nobody was eligible at the snapshot (the pinned list is empty): prove the round for the record and
    ///         return the prize to its pot.
    function rollover(uint256 id, bytes calldata drandSignature) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        Draw storage d = _open(id);
        if (d.totalWeight != 0) revert WrongStage(); // somebody was eligible: settle
        bytes32 rnd = beacon.prove(d.drandRound, drandSignature);
        d.randomWord = uint256(keccak256(abi.encode(rnd, id)));
        d.settled = true;
        activeDraw[d.track] = 0;
        _return(d);
        emit RolledOver(id, d.root);
    }

    // ------------------------------------------------------------------ guardian / anyone
    /// @notice The guardian may cancel a committed draw while its round is still in the future (a list it has
    ///         checked and found dishonest). Once the round's time has passed the outcome is public and nobody may
    ///         cancel, until ABANDON_AFTER later, when anyone may, so a dead keeper can't lock a prize. The prize
    ///         goes back to its pot.
    function cancel(uint256 id) external nonReentrant {
        Draw storage d = _open(id);
        uint256 roundTime = beacon.roundTime(d.drandRound);
        if (block.timestamp < roundTime) {
            if (msg.sender != guardian) revert NotGuardian();
        } else if (block.timestamp < roundTime + ABANDON_AFTER) {
            revert TooEarly();
        }
        d.cancelled = true;
        activeDraw[d.track] = 0;
        _return(d);
        emit Cancelled(id);
    }

    /// @notice Replace the keeper (a hot wallet) between draws. Guardian only.
    function setKeeper(address keeper_) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (keeper_ == address(0)) revert ZeroAddress();
        if (activeDraw[Track.Regular] != 0 || activeDraw[Track.Mega] != 0) revert TrackBusy();
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    /// @notice A prize whose send failed is credited; the winner (or anyone, for them) claims it here.
    function claim(address to) external nonReentrant {
        uint256 amt = _takeCredit(to);
        (bool ok,) = payable(to).call{value: amt}("");
        if (!ok) revert SendFailed();
        emit Claimed(to, amt);
    }

    /// @notice A credited winner that can't receive ETH itself (a contract without a payable fallback) may send
    ///         its credit somewhere it can.
    function redirectCredit(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amt = _takeCredit(msg.sender);
        (bool ok,) = payable(to).call{value: amt}("");
        if (!ok) revert SendFailed();
        emit CreditRedirected(msg.sender, to, amt);
    }

    /// @notice A credit nobody has collected for CREDIT_EXPIRY goes back to the regular pot. Anyone may call it.
    function expireCredit(address from) external nonReentrant {
        if (block.timestamp < creditedAt[from] + CREDIT_EXPIRY) revert TooEarly();
        uint256 amt = _takeCredit(from);
        potRegular += amt;
        emit CreditExpired(from, amt);
        emit Funded(Track.Regular, amt);
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
            creditedAt[to] = block.timestamp;
            emit PayoutCredited(to, amount);
        }
    }

    function _takeCredit(address from) internal returns (uint256 amt) {
        amt = unclaimed[from];
        if (amt == 0) revert NoDraw();
        unclaimed[from] = 0;
        unclaimedTotal -= amt;
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
