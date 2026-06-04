// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { SchemaRegistry } from "../contracts/SchemaRegistry.sol";
import { ISchemaRegistry, SchemaRecord } from "../contracts/interfaces/ISchemaRegistry.sol";

contract SchemaRegistryTest is Test {
    SchemaRegistry public registry;
    address public alice = makeAddr("alice");

    function setUp() public {
        registry = new SchemaRegistry();
    }

    function test_register_basic() public {
        // Given
        vm.prank(alice);

        // When
        uint256 id = registry.register("bool like", true, false, address(0));

        // Then
        assertEq(id, 1);
        SchemaRecord memory record = registry.getSchema(id);
        assertEq(record.id, 1);
        assertEq(record.registerer, alice);
        assertEq(record.revocable, true);
        assertEq(keccak256(bytes(record.schema)), keccak256("bool like"));
    }

    function test_register_nonRevocable() public {
        // Given/ When
        uint256 id = registry.register("bytes32 proposalId, bool vote", false, false, address(0));

        // Then
        SchemaRecord memory record = registry.getSchema(id);
        assertEq(record.revocable, false);
    }

    function test_register_incrementsCounter() public {
        // Given/ When
        uint256 id1 = registry.register("bool a", true, false, address(0));
        uint256 id2 = registry.register("bool b", true, false, address(0));
        uint256 id3 = registry.register("bool c", false, false, address(0));

        // Then
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(registry.schemaCount(), 3);
    }

    function test_register_emitsEvent() public {
        // Given
        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit ISchemaRegistry.Registered(1, alice, SchemaRecord(0, address(0), address(0), false, false, ""));

        // When/ Then
        registry.register("bool like", true, false, address(0));
    }

    function test_register_revertsOnEmptySchema() public {
        // Given
        vm.expectRevert(ISchemaRegistry.SchemaRegistry__EmptySchema.selector);

        // When/ Then
        registry.register("", true, false, address(0));
    }

    function test_getSchema_returnsEmpty_forNonExistent() public view {
        // Given/ When
        SchemaRecord memory record = registry.getSchema(999);

        // Then
        assertEq(record.id, 0);
        assertEq(record.registerer, address(0));
        assertEq(record.revocable, false);
        assertEq(bytes(record.schema).length, 0);
    }

    function test_schemaCount_startsAtZero() public view {
        // Given/ When
        uint256 count = registry.schemaCount();

        // Then
        assertEq(count, 0);
    }
}
