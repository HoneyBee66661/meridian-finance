// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Counter
/// @notice Deploy target for lifecycle tests: increments per call.
contract Counter {
    uint256 public count;

    function inc() external {
        unchecked {
            ++count;
        }
    }
}

/// @title DeployerProbe
/// @notice Lab contract proving CREATE/CREATE2 address derivation.
/// @dev Pedagogical only — NOT part of the Meridian protocol.
contract DeployerProbe {

    /// @dev CREATE prediction: keccak256(rlp([sender, nonce]))[12:]
    ///      RLP: sender = 20-byte string (0x94 prefix), nonce = single byte
    ///      (< 0x80), payload 22 bytes -> list header 0xd6.
    function predictCreate(address sender, uint256 nonce)
        public
        pure
        returns (address)
    {
        require(nonce < 0x80, "predictCreate: lab supports nonce < 0x80");
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xd6), // rlp list header: 22-byte payload
            bytes1(0x94), // rlp string header: 20-byte address
            bytes20(sender), // the address bytes
            bytes1(uint8(nonce)) // rlp string: nonce < 0x80
        )))));
    }

    /// @dev CREATE2 prediction per EIP-1014.
    function predictCreate2(address deployer, bytes32 salt, bytes memory initcode)
        public
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            keccak256(initcode)
        )))));
    }

    /// @dev Deploys with CREATE; the test predicts via vm.getNonce.
    function deployCreate() external returns (address actual) {
        actual = address(new Counter());
    }

    /// @dev Deploys with CREATE2; salt is caller-chosen.
    function deployCreate2(bytes32 salt)
        external
        returns (address actual, address predicted)
    {
        bytes memory initcode = type(Counter).creationCode;
        predicted = predictCreate2(address(this), salt, initcode);
        actual = address(new Counter{salt: salt}());
    }

    /// @dev EIP-1167 minimal proxy, implementation embedded via CREATE2.
    function deployMinimalProxy(address impl) external returns (address proxy) {
        bytes20 target = bytes20(impl);
        assembly ("memory-safe") {
            let c := mload(0x40)
            mstore(c, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(c, 0x14), target)
            mstore(add(c, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            proxy := create(0, c, 0x37)
        }
    }
}
