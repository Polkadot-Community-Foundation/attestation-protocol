// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import {ISchemaRegistry, SchemaRecord} from "./interfaces/ISchemaRegistry.sol";
import {IAttestationResolver} from "./interfaces/IAttestationResolver.sol";
import {EIP712Verifier} from "./EIP712Verifier.sol";
import {Semver} from "./Semver.sol";

import {Attestation, AttestationRequest, AttestationRequestData, DelegatedAttestationRequest, DelegatedRevocationRequest, IAttestationService, MultiAttestationRequest, MultiDelegatedAttestationRequest, MultiDelegatedRevocationRequest, MultiRevocationRequest, NO_EXPIRATION_TIME, RevocationRequest, RevocationRequestData} from "./interfaces/IAttestationService.sol";

/// @title AttestationService
/// @notice The global attestation service.
contract AttestationService is
    IAttestationService,
    EIP712Verifier,
    Semver(1, 1, 0)
{
    // The global schema registry.
    ISchemaRegistry private immutable _schemaRegistry;

    /// @inheritdoc IAttestationService
    uint256 public attestationCount;

    // The global mapping between attestation IDs and their records.
    mapping(uint256 id => Attestation) private _attestations;

    // The global mapping between data and their timestamps.
    mapping(bytes32 data => uint64 timestamp) private _timestamps;

    // The global mapping between revokers, data, and their off-chain revocation timestamps.
    mapping(address revoker => mapping(bytes32 data => uint64 timestamp))
        private _revocationsOffchain;

    /// @dev Creates a new AttestationService instance.
    /// @param registry The address of the global schema registry.
    constructor(
        ISchemaRegistry registry
    ) EIP712Verifier("AttestationService", "1") {
        if (address(registry) == address(0)) {
            revert AttestationService__InvalidRegistry();
        }
        _schemaRegistry = registry;
    }

    /// @inheritdoc IAttestationService
    function attest(
        AttestationRequest calldata request
    ) external returns (uint256) {
        AttestationRequestData[] memory data = new AttestationRequestData[](1);
        data[0] = request.data;
        return _attest(request.schema, data, msg.sender)[0];
    }

    /// @inheritdoc IAttestationService
    function attestByDelegation(
        DelegatedAttestationRequest calldata delegatedRequest
    ) external returns (uint256) {
        _verifyAttest(delegatedRequest);

        AttestationRequestData[] memory data = new AttestationRequestData[](1);
        data[0] = delegatedRequest.data;
        return
            _attest(delegatedRequest.schema, data, delegatedRequest.attester)[
                0
            ];
    }

    /// @inheritdoc IAttestationService
    function multiAttest(
        MultiAttestationRequest[] calldata multiRequests
    ) external returns (uint256[] memory) {
        uint256 length = multiRequests.length;
        uint256[][] memory totalIDs = new uint256[][](length);
        uint256 totalCount = 0;

        for (uint256 i = 0; i < length; ++i) {
            MultiAttestationRequest calldata multiRequest = multiRequests[i];
            if (multiRequest.data.length == 0) {
                revert AttestationService__InvalidLength();
            }

            uint256[] memory ids = _attest(
                multiRequest.schema,
                multiRequest.data,
                msg.sender
            );
            totalIDs[i] = ids;
            unchecked {
                totalCount += ids.length;
            }
        }

        return _mergeIDs(totalIDs, totalCount);
    }

    /// @inheritdoc IAttestationService
    function multiAttestByDelegation(
        MultiDelegatedAttestationRequest[] calldata multiDelegatedRequests
    ) external returns (uint256[] memory) {
        uint256 length = multiDelegatedRequests.length;
        uint256[][] memory totalIDs = new uint256[][](length);
        uint256 totalCount = 0;

        for (uint256 i = 0; i < length; ++i) {
            MultiDelegatedAttestationRequest
                calldata req = multiDelegatedRequests[i];
            uint256 dataLength = req.data.length;
            if (dataLength == 0 || dataLength != req.signatures.length) {
                revert AttestationService__InvalidLength();
            }

            // Verify signatures first, then attest the whole batch in one _attest call.
            for (uint256 j = 0; j < dataLength; ++j) {
                _verifyAttest(
                    DelegatedAttestationRequest({
                        schema: req.schema,
                        data: req.data[j],
                        signature: req.signatures[j],
                        attester: req.attester,
                        deadline: req.deadline
                    })
                );
            }

            uint256[] memory ids = _attest(req.schema, req.data, req.attester);
            totalIDs[i] = ids;
            unchecked {
                totalCount += ids.length;
            }
        }

        return _mergeIDs(totalIDs, totalCount);
    }

    /// @inheritdoc IAttestationService
    function revoke(RevocationRequest calldata request) external {
        RevocationRequestData[] memory data = new RevocationRequestData[](1);
        data[0] = request.data;
        _revoke(request.schema, data, msg.sender);
    }

    /// @inheritdoc IAttestationService
    function revokeByDelegation(
        DelegatedRevocationRequest calldata delegatedRequest
    ) external {
        _verifyRevoke(delegatedRequest);

        RevocationRequestData[] memory data = new RevocationRequestData[](1);
        data[0] = delegatedRequest.data;
        _revoke(delegatedRequest.schema, data, delegatedRequest.revoker);
    }

    /// @inheritdoc IAttestationService
    function multiRevoke(
        MultiRevocationRequest[] calldata multiRequests
    ) external {
        uint256 length = multiRequests.length;
        for (uint256 i = 0; i < length; ++i) {
            MultiRevocationRequest calldata multiRequest = multiRequests[i];
            if (multiRequest.data.length == 0) {
                revert AttestationService__InvalidLength();
            }

            _revoke(multiRequest.schema, multiRequest.data, msg.sender);
        }
    }

    /// @inheritdoc IAttestationService
    function multiRevokeByDelegation(
        MultiDelegatedRevocationRequest[] calldata multiDelegatedRequests
    ) external {
        uint256 length = multiDelegatedRequests.length;
        for (uint256 i = 0; i < length; ++i) {
            MultiDelegatedRevocationRequest
                calldata req = multiDelegatedRequests[i];
            uint256 dataLength = req.data.length;
            if (dataLength == 0 || dataLength != req.signatures.length) {
                revert AttestationService__InvalidLength();
            }

            // Verify signatures first, then revoke the whole batch in one _revoke call.
            for (uint256 j = 0; j < dataLength; ++j) {
                _verifyRevoke(
                    DelegatedRevocationRequest({
                        schema: req.schema,
                        data: req.data[j],
                        signature: req.signatures[j],
                        revoker: req.revoker,
                        deadline: req.deadline
                    })
                );
            }

            _revoke(req.schema, req.data, req.revoker);
        }
    }

    /// @inheritdoc IAttestationService
    function timestamp(bytes32 data) external returns (uint64) {
        uint64 time = _time();
        _timestamp(data, time);
        return time;
    }

    /// @inheritdoc IAttestationService
    function multiTimestamp(bytes32[] calldata data) external returns (uint64) {
        uint64 time = _time();
        uint256 length = data.length;
        for (uint256 i = 0; i < length; ++i) {
            _timestamp(data[i], time);
        }
        return time;
    }

    /// @inheritdoc IAttestationService
    function revokeOffchain(bytes32 data) external returns (uint64) {
        uint64 time = _time();
        _revokeOffchain(msg.sender, data, time);
        return time;
    }

    /// @inheritdoc IAttestationService
    function multiRevokeOffchain(
        bytes32[] calldata data
    ) external returns (uint64) {
        uint64 time = _time();
        uint256 length = data.length;
        for (uint256 i = 0; i < length; ++i) {
            _revokeOffchain(msg.sender, data[i], time);
        }
        return time;
    }

    /// @inheritdoc IAttestationService
    function getSchemaRegistry() external view returns (ISchemaRegistry) {
        return _schemaRegistry;
    }

    /// @inheritdoc IAttestationService
    function getAttestationById(
        uint256 id
    ) external view returns (Attestation memory) {
        return _attestations[id];
    }

    /// @inheritdoc IAttestationService
    function getAttestationByIds(
        uint256[] calldata ids
    ) external view returns (Attestation[] memory) {
        Attestation[] memory results = new Attestation[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            results[i] = _attestations[ids[i]];
        }
        return results;
    }

    /// @inheritdoc IAttestationService
    function isAttestationValid(uint256 id) public view returns (bool) {
        return _attestations[id].id != 0;
    }

    /// @inheritdoc IAttestationService
    function isActive(uint256 id) public view returns (bool) {
        if (!isAttestationValid(id)) return false;
        Attestation storage att = _attestations[id];
        if (att.revocationTime != 0) return false;
        if (att.expirationTime != 0 && block.timestamp > att.expirationTime)
            return false;
        return true;
    }

    /// @inheritdoc IAttestationService
    function getTimestamp(bytes32 data) external view returns (uint64) {
        return _timestamps[data];
    }

    /// @inheritdoc IAttestationService
    function getRevokeOffchain(
        address revoker,
        bytes32 data
    ) external view returns (uint64) {
        return _revocationsOffchain[revoker][data];
    }

    /// @dev Attests to a specific schema.
    /// @param schemaId The ID of the schema.
    /// @param data The arguments of the attestation requests.
    /// @param attester The attesting account.
    /// @return The IDs of the new attestations.
    function _attest(
        uint256 schemaId,
        AttestationRequestData[] memory data,
        address attester
    ) private returns (uint256[] memory) {
        // Ensure that we aren't attempting to attest to a non-existing schema.
        SchemaRecord memory schemaRecord = _schemaRegistry.getSchema(schemaId);
        if (schemaRecord.id == 0) revert AttestationService__InvalidSchema();

        uint256 length = data.length;
        uint256[] memory ids = new uint256[](length);

        for (uint256 i = 0; i < length; ++i) {
            AttestationRequestData memory request = data[i];

            // Ensure that either no expiration time was set or that it was set in the future.
            if (
                request.expirationTime != NO_EXPIRATION_TIME &&
                request.expirationTime <= _time()
            ) {
                revert AttestationService__InvalidExpirationTime();
            }

            // Ensure that we aren't trying to make a revocable attestation for a non-revocable schema.
            if (!schemaRecord.revocable && request.revocable) {
                revert AttestationService__Irrevocable();
            }

            // Ensure that the referenced parent attestation, if any, exists.
            if (request.refId != 0) {
                if (!isAttestationValid(request.refId)) {
                    revert AttestationService__NotFound();
                }
            }

            uint256 id;
            if (schemaRecord.unique) {
                // Unique schemas reserve one deterministic slot per (attester, recipient, schema).
                id = uint256(
                    keccak256(
                        abi.encodePacked(attester, request.recipient, schemaId)
                    )
                );
                if (_attestations[id].id != 0) {
                    // The slot already exists; overwrite in place.
                    Attestation storage attestation = _attestations[id];
                    // The `revocable` flag is locked at slot creation; reject any change on overwrite.
                    if (attestation.revocable != request.revocable) {
                        revert AttestationService__RevocableMismatch();
                    }
                    attestation.time = _time();
                    attestation.expirationTime = request.expirationTime;
                    attestation.revocationTime = 0;
                    attestation.refId = request.refId;
                    attestation.data = request.data;

                    emit Attested(request.recipient, attester, schemaId, id);

                    _callResolverOnAttest(
                        schemaRecord.resolver,
                        _attestations[id]
                    );

                    ids[i] = id;
                    continue;
                }
            } else {
                // Non-unique schemas use a sequential 1-indexed counter.
                id = ++attestationCount;
            }

            _attestations[id] = Attestation({
                id: id,
                schema: schemaId,
                refId: request.refId,
                time: _time(),
                expirationTime: request.expirationTime,
                revocationTime: 0,
                recipient: request.recipient,
                attester: attester,
                revocable: request.revocable,
                data: request.data
            });

            emit Attested(request.recipient, attester, schemaId, id);

            _callResolverOnAttest(schemaRecord.resolver, _attestations[id]);

            ids[i] = id;
        }

        return ids;
    }

    /// @dev Revokes existing attestations under a specific schema.
    /// @param schemaId The ID of the schema.
    /// @param data The arguments of the revocation requests.
    /// @param revoker The revoking account.
    function _revoke(
        uint256 schemaId,
        RevocationRequestData[] memory data,
        address revoker
    ) private {
        SchemaRecord memory schemaRecord = _schemaRegistry.getSchema(schemaId);
        if (schemaRecord.id == 0) revert AttestationService__InvalidSchema();

        uint256 length = data.length;
        for (uint256 i = 0; i < length; ++i) {
            RevocationRequestData memory request = data[i];
            Attestation storage attestation = _attestations[request.id];

            // Ensure that the attestation exists and matches the schema.
            if (attestation.id == 0) revert AttestationService__NotFound();
            if (attestation.schema != schemaId)
                revert AttestationService__WrongSchema();

            // Allow only the original attester to revoke.
            if (attestation.attester != revoker)
                revert AttestationService__AccessDenied();

            // Reject revocations on irrevocable attestations and re-revocations.
            if (!attestation.revocable)
                revert AttestationService__Irrevocable();
            if (attestation.revocationTime != 0)
                revert AttestationService__AlreadyRevoked();

            attestation.revocationTime = _time();

            emit Revoked(attestation.recipient, revoker, schemaId, request.id);

            _callResolverOnRevoke(schemaRecord.resolver, attestation);
        }
    }

    /// @dev Invokes the resolver's `onAttest` hook if one is configured.
    /// @param resolver The resolver address; address(0) skips the call.
    /// @param att The attestation to pass to the resolver.
    function _callResolverOnAttest(
        address resolver,
        Attestation memory att
    ) private {
        if (resolver == address(0)) return;
        if (!IAttestationResolver(resolver).onAttest(att)) {
            revert AttestationService__ResolverRejected();
        }
    }

    /// @dev Invokes the resolver's `onRevoke` hook if one is configured.
    /// @param resolver The resolver address; address(0) skips the call.
    /// @param att The attestation to pass to the resolver.
    function _callResolverOnRevoke(
        address resolver,
        Attestation memory att
    ) private {
        if (resolver == address(0)) return;
        if (!IAttestationResolver(resolver).onRevoke(att)) {
            revert AttestationService__ResolverRejected();
        }
    }

    /// @dev Timestamps the specified data.
    /// @param data The data to timestamp.
    /// @param time The timestamp.
    function _timestamp(bytes32 data, uint64 time) private {
        if (_timestamps[data] != 0)
            revert AttestationService__AlreadyTimestamped();
        _timestamps[data] = time;
        emit Timestamped(data, time);
    }

    /// @dev Records an off-chain revocation for the (revoker, data) pair.
    /// @param revoker The revoking account.
    /// @param data The data to revoke.
    /// @param time The timestamp.
    function _revokeOffchain(
        address revoker,
        bytes32 data,
        uint64 time
    ) private {
        if (_revocationsOffchain[revoker][data] != 0)
            revert AttestationService__AlreadyRevokedOffchain();
        _revocationsOffchain[revoker][data] = time;
        emit RevokedOffchain(revoker, data, time);
    }

    /// @dev Flattens a list of ID lists into a single array.
    /// @param idLists The lists of IDs.
    /// @param totalCount The total number of IDs across all lists.
    /// @return The flattened array.
    function _mergeIDs(
        uint256[][] memory idLists,
        uint256 totalCount
    ) private pure returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](totalCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < idLists.length; ++i) {
            uint256[] memory current = idLists[i];
            for (uint256 j = 0; j < current.length; ++j) {
                ids[currentIndex] = current[j];
                unchecked {
                    ++currentIndex;
                }
            }
        }
        return ids;
    }
}
