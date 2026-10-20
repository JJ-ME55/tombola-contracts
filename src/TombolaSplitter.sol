// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Pons V2 fee escrow: creator fees in native ETH accrue here for the creatorFeeRecipient. [Hive: HiveSplitter]
interface IPonsFeeEscrow {
    function claim() external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
}

interface ITombolaDrawPots {
    function fundRegular() external payable;
    function fundMega() external payable;
}

/// @title TombolaSplitter
/// @notice Immutable, no admin. Set as Tombola's Pons V2 creatorFeeRecipient, so every trade's creator tax (plus
///         Pons' 0.7% kickback) accrues to it in the Pons fee escrow, in ETH. Anyone may call harvest(): it claims
///         the escrow balance and splits it by fixed shares between the draw contract's regular pot, its mega pot
///         and the team fee wallet. The shares are the original 3.5 / 1.2 / 0.9 / 0.4 plan with the liquidity
///         0.9 folded into the pot, against the 6% total: 4.4 / 1.2 / 0.4.
contract TombolaSplitter {
    uint256 public constant POT_BPS = 7333; // 4.4 / 6
    uint256 public constant MEGA_BPS = 2000; // 1.2 / 6
    uint256 public constant TEAM_BPS = 667; // 0.4 / 6
    uint256 public constant BPS = 10_000;

    ITombolaDrawPots public immutable draw;
    address public immutable teamFeeWallet;
    IPonsFeeEscrow public immutable escrow; // address(0): harvest() only splits what is already here

    uint256 public teamOwed; // a team share whose send failed waits here; it never blocks the pots

    event Harvested(uint256 claimed);
    event Distributed(uint256 pot, uint256 mega, uint256 team);
    event TeamShareHeld(uint256 amount);

    error ZeroAddress();
    error SendFailed();
    error Reentered();

    uint256 private _lock;

    constructor(ITombolaDrawPots draw_, address teamFeeWallet_, IPonsFeeEscrow escrow_) {
        if (address(draw_) == address(0) || teamFeeWallet_ == address(0)) revert ZeroAddress();
        draw = draw_;
        teamFeeWallet = teamFeeWallet_;
        escrow = escrow_;
    }

    receive() external payable {}

    /// @notice Claim any ETH the escrow holds for this contract, then split everything here. Never reverts when
    ///         there is nothing to do. Anyone may call it.
    function harvest() external {
        if (_lock == 1) revert Reentered();
        _lock = 1;
        if (address(escrow) != address(0) && escrow.balanceOf(address(this)) > 0) {
            emit Harvested(escrow.claim());
        }
        uint256 bal = address(this).balance - teamOwed;
        if (bal > 0) _distribute(bal);
        _lock = 0;
    }

    /// @notice Retry a team share that could not be delivered. Anyone may call it.
    function payTeam() external {
        if (_lock == 1) revert Reentered();
        _lock = 1;
        uint256 owed = teamOwed;
        teamOwed = 0;
        (bool ok,) = payable(teamFeeWallet).call{value: owed}("");
        if (!ok) revert SendFailed();
        _lock = 0;
    }

    function _distribute(uint256 bal) internal {
        uint256 pot = bal * POT_BPS / BPS;
        uint256 mega = bal * MEGA_BPS / BPS;
        uint256 team = bal - pot - mega; // the rounding dust goes to the team, never stays here
        draw.fundRegular{value: pot}();
        draw.fundMega{value: mega}();
        (bool ok,) = payable(teamFeeWallet).call{value: team}("");
        if (!ok) {
            teamOwed += team; // the pots are funded regardless; the team collects later via payTeam()
            emit TeamShareHeld(team);
        }
        emit Distributed(pot, mega, team);
    }
}
