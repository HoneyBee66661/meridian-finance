// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMeVDesignLab
/// @notice I-prefix interface — the auction-shaped liquidation.
interface IMeVDesignLab {
    error AuctionClosed(uint256 now, uint256 deadline);
    error NotWinner(address bidder);
    error NoBids();
    error RevealTooEarly(uint256 now, uint256 revealAt);

    function commitBid(bytes32 commitment) external;
    function revealBid(uint256 amount, bytes32 salt) external;
    function settleAuction() external;
    function auctionState()
        external
        view
        returns (uint256 deadline, uint256 revealAt, address winner, uint256 winningBid);
}
