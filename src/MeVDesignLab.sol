// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMeVDesignLab} from "./IMeVDesignLab.sol";

/// @title MeVDesignLab
/// @notice Pedagogical sealed-bid liquidation auction (commit-reveal).
/// @dev NOT part of the protocol — the Ch 35 design lab.
contract MeVDesignLab is IMeVDesignLab {
    uint256 public constant COMMIT_WINDOW = 1 hours;
    uint256 public constant REVEAL_WINDOW = 1 hours;

    uint256 public deadline;
    uint256 public revealAt;
    address public winner;
    uint256 public winningBid;
    bool public settled;

    mapping(address => bytes32) public commitments;

    constructor() {
        deadline = block.timestamp + COMMIT_WINDOW;
        revealAt = deadline; // reveal opens the moment commit closes — no dead hour
    }

    function commitBid(bytes32 commitment) external {
        if (block.timestamp > deadline) revert AuctionClosed(block.timestamp, deadline);
        commitments[msg.sender] = commitment;
    }

    function revealBid(uint256 amount, bytes32 salt) external {
        if (block.timestamp < revealAt) revert RevealTooEarly(block.timestamp, revealAt);
        if (block.timestamp > revealAt + REVEAL_WINDOW) {
            revert AuctionClosed(block.timestamp, revealAt);
        }
        bytes32 expected = keccak256(abi.encode(msg.sender, amount, salt));
        if (commitments[msg.sender] != expected) revert NotWinner(msg.sender);
        if (amount > winningBid) {
            winningBid = amount;
            winner = msg.sender;
        }
    }

    function settleAuction() external {
        if (block.timestamp < revealAt + REVEAL_WINDOW) {
            revert AuctionClosed(block.timestamp, revealAt);
        }
        if (winner == address(0)) revert NoBids();
        settled = true;
    }

    function auctionState() external view returns (uint256, uint256, address, uint256) {
        return (deadline, revealAt, winner, winningBid);
    }
}
