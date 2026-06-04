// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {
    AttestationRequestData,
    DelegatedAttestationRequest,
    DelegatedRevocationRequest,
    NO_EXPIRATION_TIME,
    RevocationRequestData,
    Signature
} from "./interfaces/IAttestationService.sol";

/// @title EIP712Verifier
/// @notice EIP-712 typed signature verifier for delegated attestations and revocations.
abstract contract EIP712Verifier is EIP712 {
    error EIP712Verifier__DeadlineExpired();
    error EIP712Verifier__InvalidSignature();
    error EIP712Verifier__InvalidNonce();

    // The hash of the data type used to relay calls to attest by signature.
    // keccak256("Attest(address attester,uint256 schema,address recipient,uint64 expirationTime,bool revocable,uint256 refId,bytes data,uint256 nonce,uint64 deadline)")
    bytes32 private constant ATTEST_TYPEHASH =
        0xad0d5d5613314ce6dfb2c9664a3715c267527e727a7dd0745ae11e7bc8d1e8a4;

    // The hash of the data type used to relay calls to revoke by signature.
    // keccak256("Revoke(address revoker,uint256 schema,uint256 id,uint256 nonce,uint64 deadline)")
    bytes32 private constant REVOKE_TYPEHASH =
        0x67d0fb4e83fac8fcf64921e87fb96a5ce7824e2b8a0ecf0226922888e8414314;

    // Replay protection nonces.
    mapping(address account => uint256 nonce) private _nonces;

    /// @notice Emitted when an account's nonce is increased.
    /// @param oldNonce The previous nonce.
    /// @param newNonce The new nonce.
    event NonceIncreased(uint256 oldNonce, uint256 newNonce);

    /// @dev Creates a new EIP712Verifier instance.
    /// @param name The user-readable name of the signing domain.
    /// @param version The current major version of the signing domain.
    constructor(string memory name, string memory version) EIP712(name, version) {}

    /// @notice Returns the EIP-712 domain separator.
    /// @return The domain separator.
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Returns the current nonce of an account.
    /// @param account The account.
    /// @return The current nonce.
    function getNonce(address account) external view returns (uint256) {
        return _nonces[account];
    }

    /// @notice Returns the EIP-712 type hash for `attest`.
    /// @return The type hash.
    function getAttestTypeHash() external pure returns (bytes32) {
        return ATTEST_TYPEHASH;
    }

    /// @notice Returns the EIP-712 type hash for `revoke`.
    /// @return The type hash.
    function getRevokeTypeHash() external pure returns (bytes32) {
        return REVOKE_TYPEHASH;
    }

    /// @notice Returns the EIP-712 name.
    /// @return The name.
    function getName() external pure returns (string memory) {
        return "AttestationService";
    }

    /// @notice Invalidates prior signatures by increasing the caller's nonce.
    /// @param newNonce The new nonce; MUST be greater than the current nonce.
    function increaseNonce(uint256 newNonce) external {
        uint256 oldNonce = _nonces[msg.sender];
        if (newNonce <= oldNonce) revert EIP712Verifier__InvalidNonce();
        _nonces[msg.sender] = newNonce;
        emit NonceIncreased(oldNonce, newNonce);
    }

    /// @dev Verifies a delegated attestation request.
    /// @param request The delegated attestation request.
    function _verifyAttest(DelegatedAttestationRequest memory request) internal {
        if (request.deadline != NO_EXPIRATION_TIME && request.deadline < _time()) {
            revert EIP712Verifier__DeadlineExpired();
        }

        AttestationRequestData memory data = request.data;
        Signature memory sig = request.signature;

        bytes32 hash = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ATTEST_TYPEHASH,
                    request.attester,
                    request.schema,
                    data.recipient,
                    data.expirationTime,
                    data.revocable,
                    data.refId,
                    keccak256(data.data),
                    _nonces[request.attester]++,
                    request.deadline
                )
            )
        );

        if (
            !SignatureChecker.isValidSignatureNow(
                request.attester,
                hash,
                abi.encodePacked(sig.r, sig.s, sig.v)
            )
        ) {
            revert EIP712Verifier__InvalidSignature();
        }
    }

    /// @dev Verifies a delegated revocation request.
    /// @param request The delegated revocation request.
    function _verifyRevoke(DelegatedRevocationRequest memory request) internal {
        if (request.deadline != NO_EXPIRATION_TIME && request.deadline < _time()) {
            revert EIP712Verifier__DeadlineExpired();
        }

        RevocationRequestData memory data = request.data;
        Signature memory sig = request.signature;

        bytes32 hash = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REVOKE_TYPEHASH,
                    request.revoker,
                    request.schema,
                    data.id,
                    _nonces[request.revoker]++,
                    request.deadline
                )
            )
        );

        if (
            !SignatureChecker.isValidSignatureNow(
                request.revoker,
                hash,
                abi.encodePacked(sig.r, sig.s, sig.v)
            )
        ) {
            revert EIP712Verifier__InvalidSignature();
        }
    }

    /// @dev Returns the current block timestamp.
    /// @return The current block timestamp.
    function _time() internal view virtual returns (uint64) {
        return uint64(block.timestamp);
    }
}
