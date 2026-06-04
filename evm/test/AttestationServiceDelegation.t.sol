// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { SchemaRegistry } from "../contracts/SchemaRegistry.sol";
import { AttestationService } from "../contracts/AttestationService.sol";
import { EIP712Verifier } from "../contracts/EIP712Verifier.sol";
import {
    AttestationRequest,
    AttestationRequestData,
    DelegatedAttestationRequest,
    DelegatedRevocationRequest,
    IAttestationService,
    MultiDelegatedAttestationRequest,
    MultiDelegatedRevocationRequest,
    NO_EXPIRATION_TIME,
    RevocationRequestData,
    Signature
} from "../contracts/interfaces/IAttestationService.sol";

/// @notice Minimal ERC-1271 mock that delegates auth to a single signer.
contract MockERC1271Wallet is IERC1271 {
    address public immutable signer;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) {
            return 0x1626ba7e;
        }
        return 0xffffffff;
    }
}

contract AttestationServiceDelegationTest is Test {
    SchemaRegistry public registry;
    AttestationService public service;

    uint256 internal constant ATTESTER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;
    address internal attester;
    address internal other;

    address internal recipient = makeAddr("recipient");
    address internal relayer = makeAddr("relayer");

    uint256 internal schemaId;

    bytes32 internal constant ATTEST_TYPEHASH =
        keccak256(
            "Attest(address attester,uint256 schema,address recipient,uint64 expirationTime,bool revocable,uint256 refId,bytes data,uint256 nonce,uint64 deadline)"
        );

    bytes32 internal constant REVOKE_TYPEHASH =
        keccak256(
            "Revoke(address revoker,uint256 schema,uint256 id,uint256 nonce,uint64 deadline)"
        );

    function setUp() public {
        attester = vm.addr(ATTESTER_PK);
        other = vm.addr(OTHER_PK);

        registry = new SchemaRegistry();
        service = new AttestationService(registry);
        schemaId = registry.register("bool like", true, false, address(0));
    }

    function test_attestTypeHash_matchesLiteral() public view {
        // Given/ When
        bytes32 onChain = service.getAttestTypeHash();

        // Then
        assertEq(onChain, ATTEST_TYPEHASH);
        assertEq(onChain, 0xad0d5d5613314ce6dfb2c9664a3715c267527e727a7dd0745ae11e7bc8d1e8a4);
    }

    function test_revokeTypeHash_matchesLiteral() public view {
        // Given/ When
        bytes32 onChain = service.getRevokeTypeHash();

        // Then
        assertEq(onChain, REVOKE_TYPEHASH);
        assertEq(onChain, 0x67d0fb4e83fac8fcf64921e87fb96a5ce7824e2b8a0ecf0226922888e8414314);
    }

    function test_attestByDelegation_happyPath() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            attester,
            schemaId,
            data,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        vm.prank(relayer);

        // When
        uint256 id = service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: attester,
                deadline: NO_EXPIRATION_TIME
            })
        );

        // Then
        assertEq(id, 1);
        assertEq(service.getAttestationById(id).attester, attester);
        assertEq(service.getAttestationById(id).recipient, recipient);
        assertEq(service.getNonce(attester), 1);
    }

    function test_revokeByDelegation_happyPath() public {
        // Given
        vm.prank(attester);
        uint256 id = service.attest(
            AttestationRequest({ schema: schemaId, data: _buildAttestData() })
        );
        Signature memory sig = _signRevoke(
            ATTESTER_PK,
            attester,
            schemaId,
            id,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        vm.prank(relayer);

        // When
        service.revokeByDelegation(
            DelegatedRevocationRequest({
                schema: schemaId,
                data: RevocationRequestData({ id: id }),
                signature: sig,
                revoker: attester,
                deadline: NO_EXPIRATION_TIME
            })
        );

        // Then
        assertGt(service.getAttestationById(id).revocationTime, 0);
        assertEq(service.getNonce(attester), 1);
    }

    function test_multiAttestByDelegation_happyPath() public {
        // Given
        AttestationRequestData[] memory data = new AttestationRequestData[](2);
        data[0] = _buildAttestData();
        data[1] = _buildAttestData();
        Signature[] memory sigs = new Signature[](2);
        uint256 nonce = service.getNonce(attester);
        sigs[0] = _signAttest(ATTESTER_PK, attester, schemaId, data[0], nonce, NO_EXPIRATION_TIME);
        sigs[1] = _signAttest(ATTESTER_PK, attester, schemaId, data[1], nonce + 1, NO_EXPIRATION_TIME);
        MultiDelegatedAttestationRequest[] memory requests =
            new MultiDelegatedAttestationRequest[](1);
        requests[0] = MultiDelegatedAttestationRequest({
            schema: schemaId,
            data: data,
            signatures: sigs,
            attester: attester,
            deadline: NO_EXPIRATION_TIME
        });
        vm.prank(relayer);

        // When
        uint256[] memory ids = service.multiAttestByDelegation(requests);

        // Then
        assertEq(ids.length, 2);
        assertEq(service.getNonce(attester), 2);
    }

    function test_multiAttestByDelegation_lengthMismatchReverts() public {
        // Given
        AttestationRequestData[] memory data = new AttestationRequestData[](2);
        data[0] = _buildAttestData();
        data[1] = _buildAttestData();
        Signature[] memory sigs = new Signature[](1);
        sigs[0] = _signAttest(
            ATTESTER_PK,
            attester,
            schemaId,
            data[0],
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        MultiDelegatedAttestationRequest[] memory requests =
            new MultiDelegatedAttestationRequest[](1);
        requests[0] = MultiDelegatedAttestationRequest({
            schema: schemaId,
            data: data,
            signatures: sigs,
            attester: attester,
            deadline: NO_EXPIRATION_TIME
        });
        vm.expectRevert(IAttestationService.AttestationService__InvalidLength.selector);

        // When/ Then
        service.multiAttestByDelegation(requests);
    }

    function test_multiRevokeByDelegation_happyPath() public {
        // Given
        vm.startPrank(attester);
        uint256 id1 = service.attest(
            AttestationRequest({ schema: schemaId, data: _buildAttestData() })
        );
        uint256 id2 = service.attest(
            AttestationRequest({ schema: schemaId, data: _buildAttestData() })
        );
        vm.stopPrank();
        RevocationRequestData[] memory data = new RevocationRequestData[](2);
        data[0] = RevocationRequestData({ id: id1 });
        data[1] = RevocationRequestData({ id: id2 });
        Signature[] memory sigs = new Signature[](2);
        uint256 nonce = service.getNonce(attester);
        sigs[0] = _signRevoke(ATTESTER_PK, attester, schemaId, id1, nonce, NO_EXPIRATION_TIME);
        sigs[1] = _signRevoke(ATTESTER_PK, attester, schemaId, id2, nonce + 1, NO_EXPIRATION_TIME);
        MultiDelegatedRevocationRequest[] memory requests =
            new MultiDelegatedRevocationRequest[](1);
        requests[0] = MultiDelegatedRevocationRequest({
            schema: schemaId,
            data: data,
            signatures: sigs,
            revoker: attester,
            deadline: NO_EXPIRATION_TIME
        });
        vm.prank(relayer);

        // When
        service.multiRevokeByDelegation(requests);

        // Then
        assertGt(service.getAttestationById(id1).revocationTime, 0);
        assertGt(service.getAttestationById(id2).revocationTime, 0);
    }

    function test_multiRevokeByDelegation_lengthMismatchReverts() public {
        // Given
        vm.prank(attester);
        uint256 id = service.attest(
            AttestationRequest({ schema: schemaId, data: _buildAttestData() })
        );
        RevocationRequestData[] memory data = new RevocationRequestData[](2);
        data[0] = RevocationRequestData({ id: id });
        data[1] = RevocationRequestData({ id: id });
        Signature[] memory sigs = new Signature[](1);
        sigs[0] = _signRevoke(
            ATTESTER_PK,
            attester,
            schemaId,
            id,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        MultiDelegatedRevocationRequest[] memory requests =
            new MultiDelegatedRevocationRequest[](1);
        requests[0] = MultiDelegatedRevocationRequest({
            schema: schemaId,
            data: data,
            signatures: sigs,
            revoker: attester,
            deadline: NO_EXPIRATION_TIME
        });
        vm.expectRevert(IAttestationService.AttestationService__InvalidLength.selector);

        // When/ Then
        service.multiRevokeByDelegation(requests);
    }

    function test_attestByDelegation_replayReverts() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            attester,
            schemaId,
            data,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        DelegatedAttestationRequest memory request = DelegatedAttestationRequest({
            schema: schemaId,
            data: data,
            signature: sig,
            attester: attester,
            deadline: NO_EXPIRATION_TIME
        });
        service.attestByDelegation(request);
        vm.expectRevert(EIP712Verifier.EIP712Verifier__InvalidSignature.selector);

        // When/ Then
        service.attestByDelegation(request);
    }

    function test_increaseNonce_happyPath() public {
        // Given
        vm.prank(attester);

        // When
        service.increaseNonce(5);

        // Then
        assertEq(service.getNonce(attester), 5);
    }

    function test_increaseNonce_revertsOnEqual() public {
        // Given
        vm.startPrank(attester);
        service.increaseNonce(5);
        vm.expectRevert(EIP712Verifier.EIP712Verifier__InvalidNonce.selector);

        // When
        service.increaseNonce(5);
        vm.stopPrank();

        // Then
    }

    function test_increaseNonce_revertsOnLower() public {
        // Given
        vm.startPrank(attester);
        service.increaseNonce(5);
        vm.expectRevert(EIP712Verifier.EIP712Verifier__InvalidNonce.selector);

        // When
        service.increaseNonce(3);
        vm.stopPrank();

        // Then
    }

    function test_increaseNonce_invalidatesPriorSignature() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            attester,
            schemaId,
            data,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        vm.prank(attester);
        service.increaseNonce(10);
        vm.expectRevert(EIP712Verifier.EIP712Verifier__InvalidSignature.selector);

        // When/ Then
        service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: attester,
                deadline: NO_EXPIRATION_TIME
            })
        );
    }

    function test_attestByDelegation_pastDeadlineReverts() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            attester,
            schemaId,
            data,
            service.getNonce(attester),
            deadline
        );
        vm.warp(deadline + 1);
        vm.expectRevert(EIP712Verifier.EIP712Verifier__DeadlineExpired.selector);

        // When/ Then
        service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: attester,
                deadline: deadline
            })
        );
    }

    function test_attestByDelegation_noExpirationDeadlineAccepted() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            attester,
            schemaId,
            data,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        vm.warp(block.timestamp + 365 days);

        // When/ Then
        service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: attester,
                deadline: NO_EXPIRATION_TIME
            })
        );
    }

    function test_attestByDelegation_wrongSignerReverts() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            OTHER_PK,
            attester,
            schemaId,
            data,
            service.getNonce(attester),
            NO_EXPIRATION_TIME
        );
        vm.expectRevert(EIP712Verifier.EIP712Verifier__InvalidSignature.selector);

        // When/ Then
        service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: attester,
                deadline: NO_EXPIRATION_TIME
            })
        );
    }

    function test_attestByDelegation_wrongAttesterAddressReverts() public {
        // Given
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            other,
            schemaId,
            data,
            service.getNonce(other),
            NO_EXPIRATION_TIME
        );
        vm.expectRevert(EIP712Verifier.EIP712Verifier__InvalidSignature.selector);

        // When/ Then
        service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: other,
                deadline: NO_EXPIRATION_TIME
            })
        );
    }

    function test_attestByDelegation_erc1271Wallet() public {
        // Given
        MockERC1271Wallet wallet = new MockERC1271Wallet(attester);
        AttestationRequestData memory data = _buildAttestData();
        Signature memory sig = _signAttest(
            ATTESTER_PK,
            address(wallet),
            schemaId,
            data,
            service.getNonce(address(wallet)),
            NO_EXPIRATION_TIME
        );

        // When
        uint256 id = service.attestByDelegation(
            DelegatedAttestationRequest({
                schema: schemaId,
                data: data,
                signature: sig,
                attester: address(wallet),
                deadline: NO_EXPIRATION_TIME
            })
        );

        // Then
        assertEq(service.getAttestationById(id).attester, address(wallet));
    }

    function _buildAttestData() internal view returns (AttestationRequestData memory) {
        return AttestationRequestData({
            recipient: recipient,
            expirationTime: NO_EXPIRATION_TIME,
            revocable: true,
            refId: 0,
            data: ""
        });
    }

    function _signAttest(
        uint256 pk,
        address attesterAddr,
        uint256 schema,
        AttestationRequestData memory data,
        uint256 nonce,
        uint64 deadline
    ) internal view returns (Signature memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTEST_TYPEHASH,
                attesterAddr,
                schema,
                data.recipient,
                data.expirationTime,
                data.revocable,
                data.refId,
                keccak256(data.data),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", service.getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Signature({ v: v, r: r, s: s });
    }

    function _signRevoke(
        uint256 pk,
        address revokerAddr,
        uint256 schema,
        uint256 id,
        uint256 nonce,
        uint64 deadline
    ) internal view returns (Signature memory) {
        bytes32 structHash = keccak256(
            abi.encode(REVOKE_TYPEHASH, revokerAddr, schema, id, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", service.getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return Signature({ v: v, r: r, s: s });
    }
}
