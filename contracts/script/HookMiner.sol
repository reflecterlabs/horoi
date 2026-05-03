// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner — minimal CREATE2 salt search for V4 hook flag bits
/// @notice Mirrors the canonical Uniswap HookMiner. Searches for a salt
///         such that the deployed address has the desired hook flag bits.
library HookMiner {
    /// @dev The lower 14 bits of the hook address encode permission flags.
    uint160 internal constant FLAG_MASK = uint160(0x3FFF);

    /// @dev Maximum loop count to avoid infinite spinning. Empirically
    ///      finding a 1-bit flag takes < 200k iterations.
    uint256 internal constant MAX_LOOP = 200_000;

    /// @notice Find a salt that produces an address with `flags` in its low 14 bits.
    /// @param deployer The CREATE2 deployer address (factory or EOA-via-canonical-deployer).
    /// @param flags The required flag bits (e.g. AFTER_SWAP_FLAG = 1<<6).
    /// @param creationCode The contract creation bytecode (type(C).creationCode).
    /// @param constructorArgs The ABI-encoded constructor args.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hook, bytes32 salt) {
        bytes memory codeWithArgs = abi.encodePacked(creationCode, constructorArgs);
        bytes32 codeHash = keccak256(codeWithArgs);

        for (uint256 i = 0; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, codeHash);
            if (uint160(hook) & FLAG_MASK == flags) {
                return (hook, salt);
            }
        }
        revert("HookMiner: salt not found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 codeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
        ))));
    }
}
