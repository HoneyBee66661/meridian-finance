// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WalletLab} from "../src/WalletLab.sol";
import {IWalletLab} from "../src/IWalletLab.sol";

contract WalletLabTest is Test {
    WalletLab internal lab;
    uint256 internal ownerKey = 0xA11CE;
    address internal owner;

    function setUp() public {
        owner = vm.addr(ownerKey);
        lab = new WalletLab(owner);
    }

    function _sign(bytes32 hash, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    function _ethHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /// @dev Valid signature + nonce + chain passes.
    function testValidUserOp() public {
        bytes32 hash = keccak256("borrow");
        bytes memory sig = _sign(_ethHash(hash), ownerKey);
        assertTrue(lab.validateUserOp(hash, 0, block.chainid, sig));
    }

    /// @dev Wrong chain rejects — the cross-chain replay invariant.
    function testWrongChainRejected() public {
        bytes32 hash = keccak256("borrow");
        bytes memory sig = _sign(_ethHash(hash), ownerKey);
        vm.expectRevert(); // WrongChain
        lab.validateUserOp(hash, 0, block.chainid + 1, sig);
    }

    /// @dev Wrong nonce rejects.
    function testWrongNonceRejected() public {
        bytes32 hash = keccak256("borrow");
        bytes memory sig = _sign(_ethHash(hash), ownerKey);
        vm.expectRevert(); // InvalidNonce
        lab.validateUserOp(hash, 1, block.chainid, sig);
    }

    /// @dev Wrong signer rejects.
    function testWrongSignerRejected() public {
        bytes32 hash = keccak256("borrow");
        bytes memory sig = _sign(_ethHash(hash), 0xBAD);
        vm.expectRevert(); // InvalidSignature
        lab.validateUserOp(hash, 0, block.chainid, sig);
    }

    /// @dev High-s (malleable) mirror of a valid signature rejects — low-s enforced.
    function testMalleableSignatureRejected() public {
        bytes32 hash = keccak256("borrow");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _ethHash(hash));
        // (r, n - s, v ^ 1) is the same signer for the same digest — must be rejected.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleated = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? 28 : 27);
        vm.expectRevert(); // InvalidSignature (low-s)
        lab.validateUserOp(hash, 0, block.chainid, malleated);
    }
}
