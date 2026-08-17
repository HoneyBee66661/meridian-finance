// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYulProbe
/// @notice Interface of the Yul & inline-assembly lab probe.
/// @dev Pedagogical only — NOT part of the Meridian protocol. Errors follow the
///      OZ v5 convention of declaring in the I-prefixed interface.
interface IYulProbe {
    /// @notice A callee returned an unexpected number of bytes.
    /// @param target The address whose returndata was rejected.
    /// @param size The actual returndatasize observed.
    error BadReturndata(address target, uint256 size);

    /// @notice The STATICCALL itself failed (reverted or ran out of gas).
    /// @param target The address that failed.
    error StaticCallFailed(address target);

    /// @notice Read the four packed fields via Solidity struct access.
    /// @return cf Collateral factor.
    /// @return rf Reserve factor.
    /// @return ts Last accrual timestamp.
    /// @return fl Flags bitfield.
    function readHeaderSolidity() external view returns (uint64 cf, uint64 rf, uint64 ts, uint64 fl);

    /// @notice Read the four packed fields with one `sload` + three shifts.
    /// @return cf Collateral factor.
    /// @return rf Reserve factor.
    /// @return ts Last accrual timestamp.
    /// @return fl Flags bitfield.
    function readHeaderAssembly() external view returns (uint64 cf, uint64 rf, uint64 ts, uint64 fl);

    /// @notice Read the four legacy (unpacked) slots via plain Solidity.
    /// @return cf Collateral factor.
    /// @return rf Reserve factor.
    /// @return ts Last accrual timestamp.
    /// @return fl Flags bitfield.
    function readFourSlotsSolidity()
        external
        view
        returns (uint64 cf, uint64 rf, uint64 ts, uint64 fl);

    /// @notice keccak256 of two uint256s, hashed in the scratch space.
    /// @param a First word.
    /// @param b Second word.
    /// @return h keccak256(a ‖ b).
    function hashPair(uint256 a, uint256 b) external pure returns (bytes32 h);

    /// @notice Copy `bytes memory` with MCOPY (EIP-5656).
    /// @param data Source bytes.
    /// @return out Byte-identical copy.
    function copyMcopy(bytes memory data) external pure returns (bytes memory out);

    /// @notice Copy `bytes memory` with an mload/mstore loop.
    /// @param data Source bytes.
    /// @return out Byte-identical copy.
    function copyLoop(bytes memory data) external pure returns (bytes memory out);

    /// @notice STATICCALL `target` and return its 32-byte returndata, or zero
    ///         for the empty-return (USDT-style) convention.
    /// @param target Address to call with empty calldata.
    /// @return result The returned word, or bytes32(0) on empty returndata.
    function staticRead(address target) external view returns (bytes32 result);
}

/// @title YulProbe
/// @notice Lab contract for memory-safe Yul: packed-slot reads, scratch-space
///         keccak256, MCOPY (EIP-5656) copies, and canonical returndata
///         capture over STATICCALL.
/// @dev Pedagogical only — NOT part of the Meridian protocol. Every assembly
///      block carries `("memory-safe")` and follows the Solidity memory-safety
///      rules: allocate via the free-memory-pointer and bump-and-commit, treat
///      0x00–0x3f as volatile scratch, never read unallocated memory, and
///      check returndatasize before decoding returndata.
contract YulProbe is IYulProbe {
    /// @notice Packed market header — one slot, four 64-bit fields (Ch 6
    ///         packing discipline). Mirror of the layout Ch 20's
    ///         `MeridianVault` will use for a market.
    /// @dev Slots: 64+64+64+64 = 256 bits exactly.
    struct PackedHeader {
        uint64 collateralFactor; // WAD-scaled (1e18 = 100%)
        uint64 reserveFactor; // WAD-scaled
        uint64 lastAccrualTs; // block.timestamp of last accrual
        uint64 flags; // bitfield: 1 = paused, 2 = oracle stale, ...
    }

    /// @notice The packed header (slot 0).
    PackedHeader public header;

    /// @notice The "before" layout: four full-width slots, one field each.
    ///         Reading all four costs four SLOADs; the packed header costs one.
    /// @dev Exists to make the packing delta measurable and CSE-proof: four
    ///      distinct slots cannot be folded by the compiler's CSE pass.
    uint256 public cfUint;
    uint256 public rfUint;
    uint256 public tsUint;
    uint256 public flUint;

    /// @notice Constructor initialises the packed header and its legacy mirror.
    constructor() {
        header = PackedHeader({
            collateralFactor: 0.9e18,
            reserveFactor: 0.1e18,
            lastAccrualTs: 1_700_000_000,
            flags: 0x3
        });
        cfUint = 0.9e18;
        rfUint = 0.1e18;
        tsUint = 1_700_000_000;
        flUint = 0x3;
    }

    // ── Packed-slot reads ────────────────────────────────────────────────────

    /// @notice Read the four packed fields via Solidity struct access.
    /// @dev Reference path: one packed slot, compiler-generated masks. Present
    ///      for the assembly-vs-solidity delta test.
    /// @return cf Collateral factor.
    /// @return rf Reserve factor.
    /// @return ts Last accrual timestamp.
    /// @return fl Flags bitfield.
    function readHeaderSolidity()
        external
        view
        returns (uint64 cf, uint64 rf, uint64 ts, uint64 fl)
    {
        cf = header.collateralFactor;
        rf = header.reserveFactor;
        ts = header.lastAccrualTs;
        fl = header.flags;
    }

    /// @notice Read the four packed fields with one `sload` + three shifts.
    /// @dev Assembly is justified here because the block expresses "load the
    ///      whole slot once and decode on the stack" explicitly — a guarantee
    ///      that survives compiler versions. Gas: 1 SLOAD (2,100 cold / 100
    ///      warm) + 4 mask/shift pairs (~3 each) + return encode.
    /// @return cf Collateral factor.
    /// @return rf Reserve factor.
    /// @return ts Last accrual timestamp.
    /// @return fl Flags bitfield.
    function readHeaderAssembly()
        external
        view
        returns (uint64 cf, uint64 rf, uint64 ts, uint64 fl)
    {
        uint256 packed;
        assembly ("memory-safe") {
            packed := sload(header.slot)
        }
        cf = uint64(packed);
        rf = uint64(packed >> 64);
        ts = uint64(packed >> 128);
        fl = uint64(packed >> 192);
    }

    /// @notice Read the four legacy slots via plain Solidity.
    /// @dev The "before packing" world: four SLOADs for the same logical data.
    /// @return cf Collateral factor.
    /// @return rf Reserve factor.
    /// @return ts Last accrual timestamp.
    /// @return fl Flags bitfield.
    function readFourSlotsSolidity()
        external
        view
        returns (uint64 cf, uint64 rf, uint64 ts, uint64 fl)
    {
        cf = uint64(cfUint);
        rf = uint64(rfUint);
        ts = uint64(tsUint);
        fl = uint64(flUint);
    }

    // ── Scratch-space keccak256 ──────────────────────────────────────────────

    /// @notice keccak256 of two uint256s, hashed in the scratch space.
    /// @dev Scratch space (0x00–0x3f) is exactly two words, so two MSTOREs +
    ///      KECCAK256(0, 64) never bump the free-memory-pointer. The block is
    ///      memory-safe: scratch writes are allowed and consumed immediately.
    ///      KECCAK256 = 30 + 6/word + expansion.
    /// @param a First word.
    /// @param b Second word.
    /// @return h keccak256(a ‖ b).
    function hashPair(uint256 a, uint256 b) external pure returns (bytes32 h) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            h := keccak256(0x00, 0x40)
        }
    }

    // ── MCOPY vs copy loop (EIP-5656, Cancun) ────────────────────────────────

    /// @notice Copy `bytes memory` with MCOPY.
    /// @dev EIP-5656: MCOPY = 3 + memory expansion, vs n × (MLOAD + MSTORE)
    ///      ≈ 6n for an n-word mload/mstore loop. Memory-safe: both regions are
    ///      already allocated.
    /// @param data Source bytes.
    /// @return out Byte-identical copy.
    function copyMcopy(bytes memory data) external pure returns (bytes memory out) {
        uint256 len = data.length;
        out = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(data, 0x20), len)
        }
    }

    /// @notice Copy `bytes memory` with an mload/mstore loop.
    /// @dev The loop form EIP-5656 replaced. Copies whole words; the final
    ///      word's tail is zero-filled by the allocator, matching MCOPY.
    /// @param data Source bytes.
    /// @return out Byte-identical copy.
    function copyLoop(bytes memory data) external pure returns (bytes memory out) {
        uint256 len = data.length;
        out = new bytes(len);
        assembly ("memory-safe") {
            let src := add(data, 0x20)
            let dst := add(out, 0x20)
            let end := add(src, and(add(len, 0x1f), not(0x1f)))
            for {} lt(src, end) {} {
                mstore(dst, mload(src))
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            }
        }
    }

    // ── Canonical returndata capture ─────────────────────────────────────────

    /// @notice STATICCALL `target` and return its 32-byte returndata, or zero
    ///         for the empty-return (USDT-style) convention.
    /// @dev The canonical memory-safe capture (OZ `Address.returnData` shape):
    ///      read the free-memory-pointer, store the length, RETURNDATACOPY the
    ///      buffer, then bump-and-commit the pointer. Empty returndata is
    ///      accepted as `bytes32(0)`; anything else reverts with `BadReturndata`.
    /// @param target Address to call with empty calldata.
    /// @return result The returned word, or bytes32(0) on empty returndata.
    function staticRead(address target) external view returns (bytes32 result) {
        bool ok;
        uint256 rds;
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, 0x00, 0x00, 0x00, 0x00)
            rds := returndatasize()
        }
        if (!ok) revert StaticCallFailed(target);
        if (rds == 0) return bytes32(0);
        if (rds != 0x20) revert BadReturndata(target, rds);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, 0x20)
            mstore(0x40, add(ptr, 0x20))
            result := mload(ptr)
        }
    }
}
