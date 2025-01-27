// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.19;

library ECDSALib {
    function toEthSignedMessageHash(bytes32 _hash) internal pure returns (bytes32 message_) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, "\x19Ethereum Signed Message:\n32")
            mstore(0x1c, _hash)
            message_ := keccak256(0x00, 0x3c)
        }

        return message_;
    }
}
