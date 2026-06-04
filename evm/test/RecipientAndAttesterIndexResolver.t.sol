// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SchemaRegistry } from "../contracts/SchemaRegistry.sol";
import { AttestationService } from "../contracts/AttestationService.sol";
import { RecipientAndAttesterIndexResolver } from "../contracts/RecipientAndAttesterIndexResolver.sol";
import {
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    IAttestationService,
    NO_EXPIRATION_TIME,
    RevocationRequest,
    RevocationRequestData
} from "../contracts/interfaces/IAttestationService.sol";

contract RecipientAndAttesterIndexResolverTest is Test {
    SchemaRegistry public registry;
    AttestationService public service;
    RecipientAndAttesterIndexResolver public resolver;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public schemaId;

    function setUp() public {
        registry = new SchemaRegistry();
        service = new AttestationService(registry);
        resolver = new RecipientAndAttesterIndexResolver(service);

        schemaId = registry.register("bool like", true, false, address(resolver));
    }

    function _attest(address recipient) internal returns (uint256) {
        return service.attest(
            AttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: NO_EXPIRATION_TIME,
                    revocable: true,
                    refId: 0,
                    data: ""
                })
            })
        );
    }

    function test_constructor_setsService() public view {
        // Given/ When
        address serviceAddress = address(resolver.getService());

        // Then
        assertEq(serviceAddress, address(service));
    }

    function test_constructor_revertsOnZeroService() public {
        // Given
        vm.expectRevert(RecipientAndAttesterIndexResolver.RecipientAndAttesterIndexResolver__InvalidService.selector);

        // When/ Then
        new RecipientAndAttesterIndexResolver(IAttestationService(address(0)));

    }

    function test_onAttest_revertsWhenCalledByNonService() public {
        // Given
        Attestation memory att = service.getAttestationById(0);
        vm.expectRevert(RecipientAndAttesterIndexResolver.RecipientAndAttesterIndexResolver__AccessDenied.selector);

        // When/ Then
        resolver.onAttest(att);

    }

    function test_onRevoke_revertsWhenCalledByNonService() public {
        // Given
        Attestation memory att = service.getAttestationById(0);
        vm.expectRevert(RecipientAndAttesterIndexResolver.RecipientAndAttesterIndexResolver__AccessDenied.selector);

        // When/ Then
        resolver.onRevoke(att);

    }

    function test_attestPopulatesBothCollections() public {
        // Given
        vm.prank(alice);

        // When
        uint256 id = _attest(bob);

        // Then
        assertEq(resolver.countByRecipientAndSchema(bob, schemaId), 1);
        assertEq(resolver.countByAttester(alice), 1);
        uint256[] memory byRecipient = resolver.listByRecipientAndSchema(bob, schemaId, 0, 10);
        assertEq(byRecipient.length, 1);
        assertEq(byRecipient[0], id);
        uint256[] memory byAttester = resolver.listByAttester(alice, 0, 10);
        assertEq(byAttester.length, 1);
        assertEq(byAttester[0], id);
    }

    function test_revokeRemovesFromBothCollections() public {
        // Given
        vm.startPrank(alice);
        uint256 id = _attest(bob);

        // When
        service.revoke(RevocationRequest({ schema: schemaId, data: RevocationRequestData({ id: id }) }));
        vm.stopPrank();

        // Then
        assertEq(resolver.countByRecipientAndSchema(bob, schemaId), 0);
        assertEq(resolver.countByAttester(alice), 0);
    }

    function test_isActiveAny_trueWhenAttesterMatches() public {
        // Given
        vm.prank(alice);
        _attest(bob);
        address[] memory attesters = new address[](2);
        attesters[0] = carol;
        attesters[1] = alice;

        // When
        bool active = resolver.isActiveAny(bob, schemaId, attesters);

        // Then
        assertTrue(active);
    }

    function test_isActiveAny_falseWhenNoMatch() public {
        // Given
        vm.prank(alice);
        _attest(bob);
        address[] memory attesters = new address[](1);
        attesters[0] = carol;

        // When
        bool active = resolver.isActiveAny(bob, schemaId, attesters);

        // Then
        assertFalse(active);
    }

    function test_isActiveAny_falseAfterRevoke() public {
        // Given
        vm.startPrank(alice);
        uint256 id = _attest(bob);
        service.revoke(RevocationRequest({ schema: schemaId, data: RevocationRequestData({ id: id }) }));
        vm.stopPrank();
        address[] memory attesters = new address[](1);
        attesters[0] = alice;

        // When
        bool active = resolver.isActiveAny(bob, schemaId, attesters);

        // Then
        assertFalse(active);
    }

    function test_listByRecipientAndSchema_pagination() public {
        // Given
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; ++i) {
            _attest(bob);
        }
        vm.stopPrank();

        // When
        uint256[] memory page1 = resolver.listByRecipientAndSchema(bob, schemaId, 0, 2);
        uint256[] memory page2 = resolver.listByRecipientAndSchema(bob, schemaId, 2, 2);
        uint256[] memory page3 = resolver.listByRecipientAndSchema(bob, schemaId, 4, 2);

        // Then
        assertEq(page1.length, 2);
        assertEq(page2.length, 2);
        assertEq(page3.length, 1);
    }

    function test_listByRecipientAndSchema_revertsOnLargePageSize() public {
        // Given
        vm.expectRevert(
            abi.encodeWithSelector(
                RecipientAndAttesterIndexResolver.RecipientAndAttesterIndexResolver__PageSizeTooLarge.selector,
                101,
                100
            )
        );

        // When/ Then
        resolver.listByRecipientAndSchema(bob, schemaId, 0, 101);

    }

    function test_listByAttester_pagination() public {
        // Given
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; ++i) {
            _attest(bob);
        }
        vm.stopPrank();

        // When
        uint256[] memory page1 = resolver.listByAttester(alice, 0, 2);
        uint256[] memory page2 = resolver.listByAttester(alice, 2, 2);
        uint256[] memory page3 = resolver.listByAttester(alice, 4, 2);

        // Then
        assertEq(page1.length, 2);
        assertEq(page2.length, 2);
        assertEq(page3.length, 1);
    }

    function test_listByAttester_revertsOnLargePageSize() public {
        // Given
        vm.expectRevert(
            abi.encodeWithSelector(
                RecipientAndAttesterIndexResolver.RecipientAndAttesterIndexResolver__PageSizeTooLarge.selector,
                101,
                100
            )
        );

        // When/ Then
        resolver.listByAttester(alice, 0, 101);

    }

    function test_uniqueSchemaOverwrite_doesNotDoubleCount() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(resolver));
        vm.startPrank(alice);
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));

        // When
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: abi.encode(true) })
        }));
        vm.stopPrank();

        // Then
        assertEq(resolver.countByRecipientAndSchema(bob, uniqueSchema), 1);
        assertEq(resolver.countByAttester(alice), 1);
    }

    function test_uniqueSchemaReattestAfterRevoke_readdsToCollections() public {
        // Given
        uint256 uniqueSchema = registry.register("bool like", true, true, address(resolver));
        uint256 deterministicId = uint256(keccak256(abi.encodePacked(alice, bob, uniqueSchema)));
        vm.startPrank(alice);
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));
        service.revoke(RevocationRequest({ schema: uniqueSchema, data: RevocationRequestData({ id: deterministicId }) }));
        uint256 emptyCount = resolver.countByRecipientAndSchema(bob, uniqueSchema);

        // When
        service.attest(AttestationRequest({
            schema: uniqueSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));
        vm.stopPrank();

        // Then
        assertEq(emptyCount, 0);
        assertEq(resolver.countByRecipientAndSchema(bob, uniqueSchema), 1);
        assertEq(resolver.countByAttester(alice), 1);
    }

    function test_schemaWithoutResolver_noCollectionWrites() public {
        // Given
        uint256 noResolverSchema = registry.register("bool flag", true, false, address(0));
        vm.prank(alice);

        // When
        service.attest(AttestationRequest({
            schema: noResolverSchema,
            data: AttestationRequestData({ recipient: bob, expirationTime: NO_EXPIRATION_TIME, revocable: true, refId: 0, data: "" })
        }));

        // Then
        assertEq(resolver.countByRecipientAndSchema(bob, noResolverSchema), 0);
        assertEq(resolver.countByAttester(alice), 0);
    }
}
