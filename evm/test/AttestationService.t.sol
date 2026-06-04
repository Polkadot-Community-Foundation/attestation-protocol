// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SchemaRegistry } from "../contracts/SchemaRegistry.sol";
import { AttestationService } from "../contracts/AttestationService.sol";
import {
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    IAttestationService,
    MultiAttestationRequest,
    MultiRevocationRequest,
    NO_EXPIRATION_TIME,
    RevocationRequest,
    RevocationRequestData
} from "../contracts/interfaces/IAttestationService.sol";
import { ISchemaRegistry } from "../contracts/interfaces/ISchemaRegistry.sol";

contract AttestationServiceTest is Test {
    SchemaRegistry public registry;
    AttestationService public service;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public schemaId;

    function setUp() public {
        registry = new SchemaRegistry();
        service = new AttestationService(registry);

        schemaId = registry.register("bool like", true, false, address(0));
    }

    function test_constructor_setsRegistry() public view {
        // Given/ When
        address registryAddress = address(service.getSchemaRegistry());

        // Then
        assertEq(registryAddress, address(registry));
    }

    function test_constructor_revertsOnZeroRegistry() public {
        // Given
        vm.expectRevert(IAttestationService.AttestationService__InvalidRegistry.selector);

        // When/ Then
        new AttestationService(ISchemaRegistry(address(0)));

    }

    function test_attest_basic() public {
        // Given
        vm.prank(alice);

        // When
        uint256 id = service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refId: 0,
                    data: abi.encode(true)
                })
            })
        );

        // Then
        assertEq(id, 1);
        Attestation memory att = service.getAttestationById(id);
        assertEq(att.id, 1);
        assertEq(att.schema, schemaId);
        assertEq(att.attester, alice);
        assertEq(att.recipient, bob);
        assertEq(att.revocable, true);
        assertEq(att.revocationTime, 0);
    }

    function test_attest_incrementsCounter() public {
        // Given
        vm.startPrank(alice);

        // When
        uint256 id1 = _attest(bob, true);
        uint256 id2 = _attest(carol, true);
        vm.stopPrank();

        // Then
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(service.attestationCount(), 2);
    }

    function test_attest_emitsEvent() public {
        // Given
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IAttestationService.Attested(bob, alice, schemaId, 1);

        // When/ Then
        _attest(bob, true);

    }

    function test_attest_withExpiration() public {
        // Given
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(alice);

        // When
        uint256 id = service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: expiry,
                    revocable: true,
                    refId: 0,
                    data: ""
                })
            })
        );

        // Then
        Attestation memory att = service.getAttestationById(id);
        assertEq(att.expirationTime, expiry);
    }

    function test_attest_revertsOnInvalidSchema() public {
        // Given
        vm.expectRevert(IAttestationService.AttestationService__InvalidSchema.selector);

        // When/ Then
        service.attest(
            AttestationRequest({
                schema: 999,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refId: 0,
                    data: ""
                })
            })
        );

    }

    function test_attest_revertsOnPastExpiration() public {
        // Given
        vm.warp(1000);
        vm.expectRevert(IAttestationService.AttestationService__InvalidExpirationTime.selector);

        // When/ Then
        service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: uint64(block.timestamp - 1),
                    revocable: true,
                    refId: 0,
                    data: ""
                })
            })
        );

    }

    function test_attest_revertsOnRevocableAgainstIrrevocableSchema() public {
        // Given
        uint256 irrevocableSchema = registry.register("string name", false, false, address(0));
        vm.expectRevert(IAttestationService.AttestationService__Irrevocable.selector);

        // When/ Then
        service.attest(
            AttestationRequest({
                schema: irrevocableSchema,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refId: 0,
                    data: ""
                })
            })
        );

    }

    function test_attest_withRefId() public {
        // Given
        vm.startPrank(alice);
        uint256 id1 = _attest(bob, true);

        // When
        uint256 id2 = service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: carol,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refId: id1,
                    data: ""
                })
            })
        );
        vm.stopPrank();

        // Then
        Attestation memory att = service.getAttestationById(id2);
        assertEq(att.refId, id1);
    }

    function test_attest_revertsOnInvalidRefId() public {
        // Given
        vm.expectRevert(IAttestationService.AttestationService__NotFound.selector);

        // When/ Then
        service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refId: 999,
                    data: ""
                })
            })
        );

    }

    function test_revoke_basic() public {
        // Given
        vm.startPrank(alice);
        uint256 id = _attest(bob, true);

        // When
        service.revoke(
            RevocationRequest({
                schema: schemaId,
                data: RevocationRequestData({ id: id })
            })
        );
        vm.stopPrank();

        // Then
        Attestation memory att = service.getAttestationById(id);
        assertGt(att.revocationTime, 0);
    }

    function test_revoke_emitsEvent() public {
        // Given
        vm.startPrank(alice);
        uint256 id = _attest(bob, true);
        vm.expectEmit(true, true, true, true);
        emit IAttestationService.Revoked(bob, alice, schemaId, id);

        // When/ Then
        service.revoke(
            RevocationRequest({
                schema: schemaId,
                data: RevocationRequestData({ id: id })
            })
        );
        vm.stopPrank();

    }

    function test_revoke_revertsOnWrongAttester() public {
        // Given
        vm.prank(alice);
        uint256 id = _attest(bob, true);
        vm.prank(bob);
        vm.expectRevert(IAttestationService.AttestationService__AccessDenied.selector);

        // When/ Then
        service.revoke(
            RevocationRequest({
                schema: schemaId,
                data: RevocationRequestData({ id: id })
            })
        );

    }

    function test_revoke_revertsOnIrrevocable() public {
        // Given
        uint256 irrevocableSchema = registry.register("string name", false, false, address(0));
        vm.startPrank(alice);
        uint256 id = service.attest(
            AttestationRequest({
                schema: irrevocableSchema,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: false,
                    refId: 0,
                    data: ""
                })
            })
        );
        vm.expectRevert(IAttestationService.AttestationService__Irrevocable.selector);

        // When/ Then
        service.revoke(
            RevocationRequest({
                schema: irrevocableSchema,
                data: RevocationRequestData({ id: id })
            })
        );
        vm.stopPrank();

    }

    function test_revoke_revertsOnAlreadyRevoked() public {
        // Given
        vm.startPrank(alice);
        uint256 id = _attest(bob, true);
        service.revoke(RevocationRequest({ schema: schemaId, data: RevocationRequestData({ id: id }) }));
        vm.expectRevert(IAttestationService.AttestationService__AlreadyRevoked.selector);

        // When/ Then
        service.revoke(RevocationRequest({ schema: schemaId, data: RevocationRequestData({ id: id }) }));
        vm.stopPrank();

    }

    function test_revoke_revertsOnWrongSchema() public {
        // Given
        uint256 otherSchema = registry.register("uint256 score", true, false, address(0));
        vm.startPrank(alice);
        uint256 id = _attest(bob, true);
        vm.expectRevert(IAttestationService.AttestationService__WrongSchema.selector);

        // When/ Then
        service.revoke(RevocationRequest({ schema: otherSchema, data: RevocationRequestData({ id: id }) }));
        vm.stopPrank();

    }

    function test_isAttestationValid() public {
        // Given
        vm.prank(alice);
        uint256 id = _attest(bob, true);

        // When
        bool validZero = service.isAttestationValid(0);
        bool validExisting = service.isAttestationValid(id);
        bool validUnknown = service.isAttestationValid(id + 1);

        // Then
        assertFalse(validZero);
        assertTrue(validExisting);
        assertFalse(validUnknown);
    }

    function test_isActive_trueForFreshAttestation() public {
        // Given
        vm.prank(alice);
        uint256 id = _attest(bob, true);

        // When
        bool active = service.isActive(id);

        // Then
        assertTrue(active);
    }

    function test_isActive_falseAfterRevocation() public {
        // Given
        vm.startPrank(alice);
        uint256 id = _attest(bob, true);
        service.revoke(RevocationRequest({ schema: schemaId, data: RevocationRequestData({ id: id }) }));
        vm.stopPrank();

        // When
        bool active = service.isActive(id);

        // Then
        assertFalse(active);
    }

    function test_isActive_falseAfterExpiration() public {
        // Given
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(alice);
        uint256 id = service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: bob,
                    expirationTime: expiry,
                    revocable: true,
                    refId: 0,
                    data: ""
                })
            })
        );

        // When
        bool activeBefore = service.isActive(id);
        vm.warp(expiry + 1);
        bool activeAfter = service.isActive(id);

        // Then
        assertTrue(activeBefore);
        assertFalse(activeAfter);
    }

    function test_multiAttest() public {
        // Given
        AttestationRequestData[] memory data = new AttestationRequestData[](2);
        data[0] = AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" });
        data[1] = AttestationRequestData({ recipient: carol, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" });
        MultiAttestationRequest[] memory reqs = new MultiAttestationRequest[](1);
        reqs[0] = MultiAttestationRequest({ schema: schemaId, data: data });
        vm.prank(alice);

        // When
        uint256[] memory ids = service.multiAttest(reqs);

        // Then
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_multiRevoke() public {
        // Given
        vm.startPrank(alice);
        uint256 id1 = _attest(bob, true);
        uint256 id2 = _attest(carol, true);
        RevocationRequestData[] memory data = new RevocationRequestData[](2);
        data[0] = RevocationRequestData({ id: id1 });
        data[1] = RevocationRequestData({ id: id2 });
        MultiRevocationRequest[] memory reqs = new MultiRevocationRequest[](1);
        reqs[0] = MultiRevocationRequest({ schema: schemaId, data: data });

        // When
        service.multiRevoke(reqs);
        vm.stopPrank();

        // Then
        assertFalse(service.isActive(id1));
        assertFalse(service.isActive(id2));
    }

    function test_timestamp() public {
        // Given
        bytes32 data = keccak256("hello");

        // When
        uint64 ts = service.timestamp(data);

        // Then
        assertEq(service.getTimestamp(data), ts);
    }

    function test_timestamp_revertsOnDuplicate() public {
        // Given
        bytes32 data = keccak256("hello");
        service.timestamp(data);
        vm.expectRevert(IAttestationService.AttestationService__AlreadyTimestamped.selector);

        // When/ Then
        service.timestamp(data);

    }

    function test_multiTimestamp() public {
        // Given
        bytes32[] memory data = new bytes32[](2);
        data[0] = keccak256("a");
        data[1] = keccak256("b");

        // When
        uint64 ts = service.multiTimestamp(data);

        // Then
        assertEq(service.getTimestamp(data[0]), ts);
        assertEq(service.getTimestamp(data[1]), ts);
    }

    function test_revokeOffchain() public {
        // Given
        bytes32 data = keccak256("offchain-att");
        vm.prank(alice);

        // When
        uint64 ts = service.revokeOffchain(data);

        // Then
        assertEq(service.getRevokeOffchain(alice, data), ts);
    }

    function test_revokeOffchain_revertsOnDuplicate() public {
        // Given
        bytes32 data = keccak256("offchain-att");
        vm.startPrank(alice);
        service.revokeOffchain(data);
        vm.expectRevert(IAttestationService.AttestationService__AlreadyRevokedOffchain.selector);

        // When/ Then
        service.revokeOffchain(data);
        vm.stopPrank();

    }

    function test_getAttestationByIds() public {
        // Given
        vm.startPrank(alice);
        uint256 id1 = _attest(bob, true);
        uint256 id2 = _attest(carol, true);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        // When
        Attestation[] memory results = service.getAttestationByIds(ids);

        // Then
        assertEq(results.length, 2);
        assertEq(results[0].recipient, bob);
        assertEq(results[1].recipient, carol);
    }

    function test_unique_deterministicId() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(0));
        uint256 expected = uint256(keccak256(abi.encodePacked(alice, bob, uniqueSchema)));
        vm.prank(alice);

        // When
        uint256 id = service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));

        // Then
        assertEq(id, expected);
        assertEq(service.getAttestationById(expected).id, expected);
    }

    function test_unique_overwritesPrevious() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(0));
        uint256 deterministicId = uint256(keccak256(abi.encodePacked(alice, bob, uniqueSchema)));
        vm.startPrank(alice);
        uint256 id1 = service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: abi.encode(true) })
        }));

        // When
        uint256 id2 = service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: abi.encode(false) })
        }));
        vm.stopPrank();

        // Then
        assertEq(id1, deterministicId);
        assertEq(id2, deterministicId);
        assertTrue(service.isActive(id2));
    }

    function test_unique_reattestAfterRevoke() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(0));
        uint256 deterministicId = uint256(keccak256(abi.encodePacked(alice, bob, uniqueSchema)));
        vm.startPrank(alice);
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));
        service.revoke(RevocationRequest({ schema: uniqueSchema, data: RevocationRequestData({ id: deterministicId }) }));

        // When
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));
        vm.stopPrank();

        // Then
        assertTrue(service.isActive(deterministicId));
    }

    function test_unique_overwriteEmitsAttested() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(0));
        uint256 deterministicId = uint256(keccak256(abi.encodePacked(alice, bob, uniqueSchema)));
        vm.startPrank(alice);
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: abi.encode(true) })
        }));
        vm.expectEmit(true, true, true, true);
        emit IAttestationService.Attested(bob, alice, uniqueSchema, deterministicId);

        // When/ Then
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: abi.encode(false) })
        }));
        vm.stopPrank();

    }

    function test_unique_overwriteRevertsOnRevocableChange() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(0));
        vm.startPrank(alice);
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));
        vm.expectRevert(IAttestationService.AttestationService__RevocableMismatch.selector);

        // When/ Then
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: false, refId: 0, data: "" })
        }));
        vm.stopPrank();

    }

    function test_unique_differentAttesterAllowed() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(0));
        vm.prank(alice);
        uint256 aliceId = service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));

        // When
        vm.prank(carol);
        uint256 carolId = service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));

        // Then
        assertTrue(aliceId != carolId);
        assertTrue(service.isActive(aliceId));
        assertTrue(service.isActive(carolId));
    }

    function test_nonUnique_allowsDuplicates() public {
        // Given
        vm.startPrank(alice);

        // When
        uint256 id1 = _attest(bob, true);
        uint256 id2 = _attest(bob, true);
        vm.stopPrank();

        // Then
        assertTrue(id1 != id2);
        assertTrue(service.isActive(id1));
        assertTrue(service.isActive(id2));
    }

    function _attest(address recipient, bool revocable) internal returns (uint256) {
        return service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: revocable,
                    refId: 0,
                    data: ""
                })
            })
        );
    }
}
