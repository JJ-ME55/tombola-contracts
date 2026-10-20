// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BLS} from "bls/libraries/BLS.sol";

/// @title DrandBeacon
/// @notice Verifies drand evmnet beacon rounds on-chain and stores each round's randomness.
///         Anyone can submit a round. There is no owner, no admin and no upgrade path.
/// @dev evmnet signs keccak256(roundNumber) on BN254 G1 with the scheme bls-bn254-unchained-on-g1.
///      Verification uses randa-mu's BLS library and the chain's BN254 precompiles.
contract DrandBeacon {
    /// @notice evmnet genesis time and period, from https://api.drand.sh/v2/beacons/evmnet/info
    uint256 public constant GENESIS = 1727521075;
    uint256 public constant PERIOD = 3;
    string public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    /// @notice Randomness of each verified round: keccak256 of its signature. Zero means not yet proven.
    mapping(uint64 => bytes32) public randomness;

    event RoundProven(uint64 indexed round, bytes32 randomness);

    error InvalidSignature();

    /// @notice evmnet's group public key on G2.
    function publicKey() public pure returns (BLS.PointG2 memory) {
        return BLS.PointG2(
            [
                0x557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,
                0x7e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382
            ],
            [
                0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b,
                0x95685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6
            ]
        );
    }

    /// @notice The first round whose publication time is at or after `timestamp`.
    function roundAt(uint256 timestamp) public pure returns (uint64) {
        if (timestamp <= GENESIS) return 1;
        return uint64((timestamp - GENESIS + PERIOD - 1) / PERIOD + 1);
    }

    /// @notice When round `round` is published.
    function roundTime(uint64 round) public pure returns (uint256) {
        return GENESIS + (uint256(round) - 1) * PERIOD;
    }

    /// @notice True if `signature` is drand's valid signature for `round`.
    function isValid(uint64 round, bytes calldata signature) public view returns (bool) {
        if (signature.length != 64) return false;
        BLS.PointG1 memory sig = BLS.g1Unmarshal(signature);
        if (!BLS.isValidSignature([sig.x, sig.y])) return false;
        // verifySingle returns (pairingSuccess, callSuccess) in that order. [A1-25]
        (bool pairingOk, bool callOk) = BLS.verifySingle(
            sig, publicKey(), BLS.hashToPoint(bytes(DST), abi.encodePacked(keccak256(abi.encodePacked(round))))
        );
        return callOk && pairingOk;
    }

    /// @notice Proves a round and stores its randomness. Proving an already-proven round is a no-op.
    function prove(uint64 round, bytes calldata signature) external returns (bytes32 value) {
        value = randomness[round];
        if (value != bytes32(0)) return value;
        if (!isValid(round, signature)) revert InvalidSignature();
        value = keccak256(signature);
        randomness[round] = value;
        emit RoundProven(round, value);
    }
}
