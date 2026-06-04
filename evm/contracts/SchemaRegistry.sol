// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import { ISchemaRegistry, SchemaRecord } from "./interfaces/ISchemaRegistry.sol";
import { Semver } from "./Semver.sol";

/// @title SchemaRegistry
/// @notice The global schema registry.
contract SchemaRegistry is ISchemaRegistry, Semver(1, 0, 0) {
    // The global counter of registered schemas.
    uint256 private _count;

    // The global mapping between schema IDs and their records.
    mapping(uint256 id => SchemaRecord) private _schemas;

    /// @inheritdoc ISchemaRegistry
    function register(
        string calldata schema,
        bool revocable,
        bool unique,
        address resolver
    ) external returns (uint256) {
        if (bytes(schema).length == 0) revert SchemaRegistry__EmptySchema();

        uint256 id = ++_count;

        _schemas[id] = SchemaRecord({
            id: id,
            registerer: msg.sender,
            resolver: resolver,
            revocable: revocable,
            unique: unique,
            schema: schema
        });

        emit Registered(id, msg.sender, _schemas[id]);

        return id;
    }

    /// @inheritdoc ISchemaRegistry
    function getSchema(uint256 id) external view returns (SchemaRecord memory) {
        return _schemas[id];
    }

    /// @inheritdoc ISchemaRegistry
    function schemaCount() external view returns (uint256) {
        return _count;
    }
}
