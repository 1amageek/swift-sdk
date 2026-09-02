# Base Protocol Core

## Purpose and Scope

Base owns the shared, state-free protocol vocabulary used by the `MCP` module:
JSON-RPC request/response/notification values, `Value`, IDs, typed MCP errors,
version and lifecycle models, and the internal modern codec and tool-header
resolver introduced by this work.

Parent: [MCP module](../DESIGN.md).

Related child components:

- [Transport](Transports/DESIGN.md)
- [Authorization](Authorization/DESIGN.md)
- [Utilities](Utilities) (existing source grouping; no separate design unit)

## Responsibilities and Boundaries

Base generates and consumes protocol values; it does not open connections,
dispatch handlers, retain pending requests, or ask users for input. The codec is
one concrete internal implementation, not a protocol hierarchy or factory.
`ToolHeaderResolver` is a pure schema/value operation and does not perform
network `$ref` resolution.

Base does not own the HTTP `ExchangeID`, connection negotiation state, OAuth
credential lifecycle, application persistence, or Tasks.

## Related Designs

| Design | Relationship | Contract used | Cautions |
| --- | --- | --- | --- |
| [MCP module](../DESIGN.md) | parent | module public surface and dependency direction | keep the core independent of transport implementations |
| [Transport](Transports/DESIGN.md) | sibling/used by orchestration | raw bytes and exchange delivery | Base supplies payloads; Transport supplies delivery |
| [Authorization](Authorization/DESIGN.md) | child/sibling protocol support | typed OAuth data and validation errors | OAuth HTTP calls remain outside the codec |
| [Client](../Client/DESIGN.md) | used by | request metadata, result metadata, and header derivation | Client owns retry and pending state |
| [Server](../Server/DESIGN.md) | used by | request validation, MRTR results, and discovery models | Server owns dispatch and semantic state |

## Architecture

```mermaid
flowchart LR
    Input[Typed values / Data]
    Codec[One internal MessageCodec]
    Models[Request, Result, Notification,<br/>Value, metadata, errors]
    Headers[Pure ToolHeaderResolver]
    Output[Typed values / Data]

    Input --> Codec --> Output
    Models <--> Codec
    Models --> Headers
```

The codec is the sole owner of era-specific wire representation. Existing
legacy representations remain lossless. Modern fields are validated and
encoded by the same concrete codec rather than by separate legacy and modern
model trees.

## Contracts and Invariants

| Contract | Guarantee |
| --- | --- |
| JSON-RPC compatibility | Existing legacy request, response, notification, and arbitrary `Value` payloads remain decodable and encodable without semantic loss. |
| Era-aware wire rules | Supported legacy-family behavior (`2024-11-05` through `2025-11-25`) remains tolerant where the existing API requires it; `2026-07-28` requires request `_meta` and response `resultType` where the modern schema requires them. |
| Metadata | Modern request metadata contains required protocol version and client capability fields; optional client info and extension fields remain distinguishable. Result cache hints and opaque request state are preserved as values. |
| MRTR values | Input-required results distinguish complete from input-required state, preserve opaque `requestState`, and carry keyed input requests/responses without inventing application decisions. |
| Subscription values | Subscription filters, acknowledgement metadata, and terminal results are represented as protocol data; stream ownership remains in orchestration/transport. |
| Header derivation | Only statically reachable `properties` are visited. Invalid or duplicate `x-mcp-header` annotations exclude the tool; null/missing values are omitted; string/integer/boolean values use the specified safe encoding. |
| Schema boundary | Tool-header schema walks are local and positively bounded by the resolver; network `$ref` targets are never fetched. Client owns paginated tool discovery, `maxToolListPages = 64`, and cursor-cycle failures. |
| Failure | Missing/invalid modern fields, mismatched versions, unsupported capabilities, invalid header annotations, and local schema-walk exhaustion produce typed failures rather than empty success. Client reports pagination-bound and cursor-cycle failures. |

`ConnectionInfo`, `ProtocolEra`, and typed modern failure values are internal or
public only at the API boundary where the module design requires them. Their
ownership and exposure are defined by the Client design; Base only defines
their wire meaning.

## Runtime Flows

```mermaid
sequenceDiagram
    participant Owner as Client or Server
    participant Core as Base protocol core
    participant Value as Typed model

    Owner->>Core: encode request/result
    Core->>Value: validate era-required fields
    Value-->>Core: lossless wire value
    Core-->>Owner: Data or typed failure
    Owner->>Core: decode response/notification
    Core-->>Owner: typed value or typed failure
```

Header derivation is a bounded, pure operation over one tool schema and one
argument value. It has no I/O and cannot mutate the tool registry or a
connection.

## State, Ownership, and Lifecycle

The codec and resolver retain no cross-request mutable state. A caller owns the
input and result values for the operation. Opaque request state is copied as a
protocol value only for the request lifetime; it is not used as a server-side
session key by Base.

## Failure, Concurrency, and Constraints

- Base values are `Sendable` where the public module contract requires it; no
  shared mutable registry is introduced.
- A modern result must identify whether it is complete or requires input. A
  legacy result without `resultType` is interpreted as complete only on the
  legacy path.
- Resolver traversal stops at its positive local schema-walk bound and never
  dereferences a network `$ref`.
- Client owns paginated tool discovery, with positive `maxToolListPages` default
  `64`; cursor cycles and page-bound exhaustion are failures, not infinite loops.
- Unknown extension fields are preserved where the existing `Value`/metadata
  contract permits, while malformed required fields fail decoding.

## Verification and Change Impact

Focused protocol-core tests must prove legacy wire fixtures, modern required
fields, MRTR/subscription round trips, invalid result/input combinations,
header annotation validation, safe value encoding, and the network-ref
no-dereference rule. These tests own Base invariants; Client and
Server integration tests must not replace them.

Changes to wire fields, error codes, metadata requirements, schema traversal, or
the positive limit require rechecking the module master and Client, Server, and
Transport designs.
