# Attestation Protocol Specification V2

## Overview

A protocol for making, revoking, and verifying claims about accounts. Any account can register a schema and issue attestations under it.

The protocol is designed around user flows like these:

1. **As a Browse user**, I want to recommend apps so my contacts can see them.

2. **As a zkBeerTap user**, I want to prove my age once to a trusted verifier and have every participating bar accept it.

3. **As a W3S Playground contributor**, I want to rate 1-5 other people's applications.

## Architecture

```
┌─────────────────────┐    reads schema metadata     ┌────────────────────────┐
│   SchemaRegistry    │ ◄──────────────────────────  │   AttestationService   │
│                     │                              │                        │
│  • register()       │                              │  • attest / revoke     │
│  • getSchema()      │                              │  • multi* / *Delegated │
│  • schemaCount()    │                              │  • timestamp           │
└─────────────────────┘                              │  • revokeOffchain      │
                                                     │  • getAttestation*     │
                                                     │  • isActive            │
                                                     └────────────┬───────────┘
                                                                  │
                                              calls onAttest /    │
                                              onRevoke per item   │
                                                                  ▼
                                                     ┌───────────────────────────────────┐
                                                     │ IAttestationResolver              │
                                                     │ (per-schema, optional)            │
                                                     │                                   │
                                                     │ Reference impl:                   │
                                                     │ RecipientAndAttesterIndexResolver │
                                                     │  • listBy* / countBy*             │
                                                     │  • isActiveAny                    │
                                                     └───────────────────────────────────┘
```

`AttestationService` holds an immutable reference to the `SchemaRegistry` it was constructed with. There is no upgrade or admin path on either contract.

The core `AttestationService` stores attestations by id and emits event. Discovery is delegated to per-schema `IAttestationResolver` implementations, optionally configured at schema registration. A reference resolver (`RecipientAndAttesterIndexResolver`) ships with the protocol and reproduces the listing surface that earlier versions had built into the core.

## Common Types

### Constants

```solidity
/// @dev A zero expiration represents a non-expiring attestation.
uint64 constant NO_EXPIRATION_TIME = 0;
```

### `SchemaRecord`

```solidity
struct SchemaRecord {
    uint256 id;          // Sequential identifier of the schema.
    address registerer;  // The address that registered this schema.
    address resolver;    // Optional `IAttestationResolver` called on attest/revoke; address(0) means none.
    bool revocable;      // Whether attestations under this schema can be revoked.
    bool unique;         // Whether duplicates are rejected per (attester, recipient, schema).
    string schema;       // Schema spec (e.g., a Solidity ABI-style descriptor).
}
```

### `Attestation`

```solidity
struct Attestation {
    uint256 id;             // Sequential or deterministic identifier (see "Identifier rules").
    uint256 schema;         // Schema this attestation conforms to.
    uint64 time;            // Unix timestamp the attestation was created or last overwritten.
    uint64 expirationTime;  // Unix timestamp; 0 means never expires.
    uint64 revocationTime;  // Unix timestamp; 0 means not revoked.
    uint256 refId;          // Optional parent attestation id; 0 means none.
    address recipient;      // Subject of the claim.
    address attester;       // Author of the claim.
    bool revocable;         // Whether the attester can revoke this attestation.
    bytes data;             // Schema-defined ABI-encoded payload.
}
```

### Request types

```solidity
struct AttestationRequestData {
    address recipient;
    uint64 expirationTime;
    bool revocable;
    uint256 refId;
    bytes data;
}

struct AttestationRequest {
    uint256 schema;
    AttestationRequestData data;
}

struct MultiAttestationRequest {
    uint256 schema;
    AttestationRequestData[] data;
}

struct RevocationRequestData {
    uint256 id;
}

struct RevocationRequest {
    uint256 schema;
    RevocationRequestData data;
}

struct MultiRevocationRequest {
    uint256 schema;
    RevocationRequestData[] data;
}
```

### Delegation types

```solidity
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct DelegatedAttestationRequest {
    uint256 schema;
    AttestationRequestData data;
    Signature signature;
    address attester;
    uint64 deadline;
}

struct MultiDelegatedAttestationRequest {
    uint256 schema;
    AttestationRequestData[] data;
    Signature[] signatures;
    address attester;
    uint64 deadline;
}

struct DelegatedRevocationRequest {
    uint256 schema;
    RevocationRequestData data;
    Signature signature;
    address revoker;
    uint64 deadline;
}

struct MultiDelegatedRevocationRequest {
    uint256 schema;
    RevocationRequestData[] data;
    Signature[] signatures;
    address revoker;
    uint64 deadline;
}
```

## Errors

All errors are namespaced with the contract that declares them, using the `<Contract>__<Name>` convention.

```solidity
// SchemaRegistry
error SchemaRegistry__EmptySchema();
error SchemaRegistry__SchemaNotFound(uint256 id);

// AttestationService
error AttestationService__AccessDenied();
error AttestationService__AlreadyRevoked();
error AttestationService__AlreadyRevokedOffchain();
error AttestationService__AlreadyTimestamped();
error AttestationService__InvalidExpirationTime();
error AttestationService__InvalidLength();
error AttestationService__InvalidRegistry();
error AttestationService__InvalidSchema();
error AttestationService__Irrevocable();
error AttestationService__NotFound();
error AttestationService__ResolverRejected();
error AttestationService__RevocableMismatch();
error AttestationService__WrongSchema();
```

Delegation errors (`DeadlineExpired`, `InvalidSignature`, `InvalidNonce`) come from the EIP-712 verification layer.

## Events

```solidity
event Registered(
    uint256 indexed id,
    address indexed registerer,
    SchemaRecord schema
);

event Attested(
    address indexed recipient,
    address indexed attester,
    uint256 indexed schema,
    uint256 id
);

event Revoked(
    address indexed recipient,
    address indexed attester,
    uint256 indexed schema,
    uint256 id
);

event Timestamped(
    bytes32 indexed data,
    uint64 indexed timestamp
);

event RevokedOffchain(
    address indexed revoker,
    bytes32 indexed data,
    uint64 indexed timestamp
);

event NonceIncreased(uint256 oldNonce, uint256 newNonce);
```

## Identifier rules

For schemas with `unique = false`:

```
id = ++attestationCount   // sequential, 1-indexed; 0 indicates non-existent.
```

For schemas with `unique = true`:

```
id = uint256(keccak256(abi.encodePacked(attester, recipient, schemaId)))
```

This makes the id deterministic and computable off-chain. Callers MAY look up an attestation directly without first listing the collection.

## Schema Registry API

### Write Methods

#### `register`

```solidity
function register(
    string calldata schema,
    bool revocable,
    bool unique,
    address resolver
) external returns (uint256 id);
```

Registers a new schema and returns its 1-indexed id (0 means non-existent). `resolver` is the address of an `IAttestationResolver` to invoke on attest/revoke; pass `address(0)` for none. Reverts with `SchemaRegistry__EmptySchema` on empty input. The registry does not deduplicate — identical inputs produce distinct schemas with distinct ids.

### View Methods

#### `getSchema`

```solidity
function getSchema(uint256 id) external view returns (SchemaRecord memory);
```

Returns the schema record for `id`. If `id` does not exist, the returned `SchemaRecord` MUST be the zero-valued struct (`record.id == 0`).

#### `schemaCount`

```solidity
function schemaCount() external view returns (uint256);
```

Returns the total number of schemas ever registered.

## Attestation Service API

### `attest`

```solidity
function attest(AttestationRequest calldata request) external returns (uint256 id);
```

Creates a single attestation. The caller (`msg.sender`) is the attester.

**Validation:**
- Past expirations are rejected (`InvalidExpirationTime`).
- Revocable attestations under an irrevocable schema are rejected (`Irrevocable`).
- A non-zero `refId` MUST point to an existing attestation (`NotFound`).
- For unique schemas, re-attesting overwrites the existing slot in place. `revocationTime` is reset to 0; `recipient`, `attester`, `schema`, and `revocable` are locked at slot creation, and overwriting with a different `revocable` reverts (`RevocableMismatch`).

### `attestByDelegation`

```solidity
function attestByDelegation(
    DelegatedAttestationRequest calldata request
) external returns (uint256 id);
```

Same as `attest`, but the attester is `request.attester` and is authorized via an EIP-712 signature instead of `msg.sender`. The transaction submitter MAY be any account.

### `multiAttest`

```solidity
function multiAttest(
    MultiAttestationRequest[] calldata requests
) external returns (uint256[] memory ids);
```

Batch variant of `attest`. All items inside a single `MultiAttestationRequest` share one schema (the schema is fetched once per outer item). Returned ids are flattened in input order. Per-item validation is identical to `attest`.

### `multiAttestByDelegation`

```solidity
function multiAttestByDelegation(
    MultiDelegatedAttestationRequest[] calldata requests
) external returns (uint256[] memory ids);
```

Batch variant of `attestByDelegation`. Every signature inside one `MultiDelegatedAttestationRequest` MUST be from the same `attester` and share the same `deadline`. Per-item validation is identical to `attest`.

### `revoke`

```solidity
function revoke(RevocationRequest calldata request) external;
```

Revokes a single attestation. The caller (`msg.sender`) MUST be the original attester.

**Validation:**
- Reverts with `NotFound`, `WrongSchema`, `AccessDenied` (only the original attester can revoke), `Irrevocable`, or `AlreadyRevoked` as appropriate.
- Sets `revocationTime` to the current block time. The underlying record stays readable by id; only the collections are updated.

### `revokeByDelegation`

```solidity
function revokeByDelegation(
    DelegatedRevocationRequest calldata request
) external;
```

Same as `revoke`, but the revoker is `request.revoker` and is authorized via an EIP-712 signature. The transaction submitter MAY be any account.

### `multiRevoke`

```solidity
function multiRevoke(
    MultiRevocationRequest[] calldata requests
) external;
```

Batch variant of `revoke`. All ids within a single `MultiRevocationRequest` MUST belong to the same schema. Per-item validation is identical to `revoke`.

### `multiRevokeByDelegation`

```solidity
function multiRevokeByDelegation(
    MultiDelegatedRevocationRequest[] calldata requests
) external;
```

Batch variant of `revokeByDelegation`. Same constraints as `multiRevoke`. Per-item validation is identical to `revoke`.

### `attestationCount`

```solidity
function attestationCount() external view returns (uint256);
```

Returns the count of non-unique attestations ever issued. Unique-schema overwrites do not increment this counter.

### `timestamp`

```solidity
function timestamp(bytes32 data) external returns (uint64);
```

Anchors arbitrary `bytes32` data with the current block time. Each `data` value can be timestamped only once globally; re-timestamping reverts with `AlreadyTimestamped`. Returns the timestamp recorded.

### `multiTimestamp`

```solidity
function multiTimestamp(bytes32[] calldata data) external returns (uint64);
```

Batch variant of `timestamp`. All entries are recorded with the same timestamp.

### `revokeOffchain`

```solidity
function revokeOffchain(bytes32 data) external returns (uint64);
```

Anchors a revocation against arbitrary `bytes32` data, scoped to the caller (`msg.sender`). Each `(revoker, data)` pair can be revoked only once; re-revocation reverts with `AlreadyRevokedOffchain`. Returns the revocation time recorded.

### `multiRevokeOffchain`

```solidity
function multiRevokeOffchain(bytes32[] calldata data) external returns (uint64);
```

Batch variant of `revokeOffchain`.

## View Functions

### `getAttestationById`

```solidity
function getAttestationById(uint256 id) external view returns (Attestation memory);
```

Returns the attestation record for `id`, or the zero-valued `Attestation` if unknown.

### `getAttestationByIds`

```solidity
function getAttestationByIds(uint256[] calldata ids)
    external view returns (Attestation[] memory);
```

Returns one entry per input id in input order, zero-valued for unknowns.

### `isAttestationValid`

```solidity
function isAttestationValid(uint256 id) external view returns (bool);
```

Returns `true` iff the attestation exists (`id != 0`).

### `isActive`

```solidity
function isActive(uint256 id) external view returns (bool);
```

Returns `true` iff the attestation exists, has not been revoked, and has not expired.

### `getTimestamp`

```solidity
function getTimestamp(bytes32 data) external view returns (uint64);
```

Returns the timestamp recorded for `data`, or 0 if never timestamped.

### `getRevokeOffchain`

```solidity
function getRevokeOffchain(address revoker, bytes32 data) external view returns (uint64);
```

Returns the off-chain revocation time recorded for `(revoker, data)`, or 0 if never revoked.

## Resolver Framework

`AttestationService` invokes a per-schema `IAttestationResolver` after every attestation and revocation, when one is configured. Resolvers can implement custom indexing, allowlists, validation, or any other per-schema policy. The core contract holds no by-recipient or by-attester collections itself; apps that need on-chain composite-key queries point a schema at a resolver that maintains them.

### `IAttestationResolver`

```solidity
interface IAttestationResolver {
    function onAttest(Attestation calldata att) external returns (bool);
    function onRevoke(Attestation calldata att) external returns (bool);
}
```

`onAttest` is called after the attestation record is written and the `Attested` event is emitted. `onRevoke` is called after `revocationTime` is set and the `Revoked` event is emitted. A return of `false` reverts the call with `AttestationService__ResolverRejected`; a revert from the resolver bubbles up.

Resolver implementations SHOULD restrict callers to the bound `AttestationService` instance to prevent forged calls polluting their state.

### Reference resolver: `RecipientAndAttesterIndexResolver`

The protocol ships `RecipientAndAttesterIndexResolver`, a reference implementation that maintains by-`(recipient, schema)` and by-attester collections. Schemas point at an instance of this contract via the `resolver` field at registration to opt into the listing surface. A single resolver instance MAY be shared across schemas; collections are keyed accordingly.

```solidity
function getService() external view returns (IAttestationService);

function isActiveAny(
    address recipient,
    uint256 schema,
    address[] calldata attesters
) external view returns (bool);

function countByRecipientAndSchema(
    address recipient,
    uint256 schema
) external view returns (uint256);

function listByRecipientAndSchema(
    address recipient,
    uint256 schema,
    uint64 offset,
    uint64 limit
) external view returns (uint256[] memory);

function countByAttester(address attester) external view returns (uint256);

function listByAttester(
    address attester,
    uint64 offset,
    uint64 limit
) external view returns (uint256[] memory);
```

`isActiveAny` returns `true` if any attester in `attesters` has at least one active attestation for `(recipient, schema)` (per `AttestationService.isActive(id)`). It short-circuits on the first match. Cost is `O(N*M)` where `N` is the `(recipient, schema)` collection size and `M` is the attesters list length, with two external calls per entry. `count*` are `O(1)` and `list*` are bounded by `MAX_PAGE_SIZE` per call.

Pagination: `limit` MUST be `<= MAX_PAGE_SIZE` (`RecipientAndAttesterIndexResolver__PageSizeTooLarge` otherwise). `offset >= total` returns empty. Order is not stable across blocks since revocations swap-and-pop.

Expired attestations stay in the collections until the attester revokes them (revocable schemas only). `isActiveAny` walks them and discards them via `isActive`. For schemas with `revocable = false` and finite expiration, expired entries accumulate and the per-call cost grows monotonically.

The resolver's errors are namespaced under `RecipientAndAttesterIndexResolver__*` (not `AttestationService__*`):

```solidity
error RecipientAndAttesterIndexResolver__AccessDenied();
error RecipientAndAttesterIndexResolver__InvalidService();
error RecipientAndAttesterIndexResolver__PageSizeTooLarge(uint64 requested, uint64 max);
```

## Versioning

Both `SchemaRegistry` and `AttestationService` implement `ISemver`:

```solidity
function version() external pure returns (string memory);
```

Storage-layout breaks (additions or removals on `SchemaRecord`, changes to mapping shapes) require a major version bump and a redeploy. ABI-additive changes (new events, errors, or functions that do not change existing storage) require a minor version bump.

The protocol does not support proxy upgrades. Each deployment is permanent; new versions live at new addresses.

## References

1. OpenZeppelin Contracts, https://docs.openzeppelin.com/contracts/5.x/api/utils. Accessed 2026-04-30.
2. Ethereum Attestation Service, https://github.com/ethereum-attestation-service/eas-contracts. Accessed 2026-04-30.
3. EIP-712: Typed structured data hashing and signing, https://eips.ethereum.org/EIPS/eip-712. Accessed 2026-04-30.
