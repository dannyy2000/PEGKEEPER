// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Off-chain CREATE2 salt miner for Uniswap v4 hooks.
///         Iterates salts until the resulting address has the required
///         hook-permission bits set in its lowest 14 bits.
library HookMiner {
    /// @notice Find a salt such that CREATE2(deployer, salt, initCodeHash)
    ///         produces an address whose uint160 & flagMask == flags.
    /// @param deployer    The account that will call CREATE2 (usually the script runner).
    /// @param flags       The required bit-pattern (e.g. 0x1C80 for PegKeeper).
    /// @param flagMask    Bit-mask applied to the address before comparison (0x3FFF = 14 bits).
    /// @param initCode    Full creation bytecode including constructor arguments.
    /// @return hookAddress The mined address.
    /// @return salt        The salt to pass to CREATE2.
    function find(
        address deployer,
        uint160 flags,
        uint160 flagMask,
        bytes memory initCode
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(initCode);
        uint256 nonce = 0;

        while (true) {
            salt = bytes32(nonce);
            hookAddress = _computeAddress(deployer, salt, initCodeHash);

            if (uint160(hookAddress) & flagMask == flags) {
                return (hookAddress, salt);
            }

            unchecked { nonce++; }
        }
    }

    /// @dev Computes CREATE2 address: keccak256(0xFF ++ deployer ++ salt ++ initCodeHash)[12:]
    function _computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
}
