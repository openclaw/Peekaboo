---
summary: 'Documented lint and compiler-test exceptions that preserve released source contracts.'
read_when:
  - 'changing a released API to address a lint warning'
  - 'authoring tests for a deprecated released API'
  - 'reviewing warning-free release validation'
---

# Lint and released API compatibility

Fix warnings at their owning code boundary rather than raising repository-wide thresholds. A released source contract
may justify a declaration-local exception when a style-only change would break callers. Record the exact contract and
keep a consumer regression; an exception does not waive compiler, test, security, or artifact validation.

## Raw desktop evidence factory

[`DesktopTargetEvidenceAdapter.evidence(processIdentifier:processStartIdentity:windowID:windowIdentity:windowBounds:focusedElement:)`](../../Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Strategy/DesktopTargetEvidenceAdapter.swift)
shipped in Peekaboo 4.2.2. Its six independent inputs intentionally preserve incomplete or contradictory evidence for
later validation. Grouping or removing those labels would break source callers; replacing them with a validated target
would also change refusal semantics.

The declaration therefore has one `function_parameter_count` exception. Its signature and implementation remain
unchanged, and the [version-selected public SwiftPM consumer fixture](../../scripts/test-swiftpm-consumer.sh) compiles
all six labels. That fixture is compile-only; it does not construct runtime services. Remove the exception with the
factory only as part of an explicitly approved source-compatibility migration, not a minor-release lint cleanup.

## Deprecated compatibility test declarations

Separately from the SwiftLint factory exception above, three Swift Testing declarations intentionally use the language's
`@available(*, deprecated)` context to exercise deprecated public APIs shipped in v4.2.2
(`05675b0b5e2c382146963e19493787d9dac0d45b`):

- [`PeekabooBridgeAppleScriptCompatibilityTests`](../../Core/PeekabooCore/Tests/PeekabooTests/PeekabooBridgeAppleScriptCompatibilityTests.swift).`Legacy client probe API refuses before transport` protects the public client's local refusal before socket transport. Handshake omission and raw wire rejection do not prove this client behavior.
- [`InMemorySnapshotManagerTests`](../../Core/PeekabooAutomationKit/Tests/PeekabooAutomationKitTests/InMemorySnapshotManagerTests.swift).`legacy seeded initializer remains source compatible and rejects malformed authority` protects the synchronous initializer's callable signature, valid seeding, continued reuse, and empty-manager handling of malformed authority.
- `InMemorySnapshotManagerTests`.`legacy seeded initializer rejects mismatched embedded coordinate authority` protects the same initializer's refusal to seed contradictory snapshot/coordinate authority.

The async `containing` factory uses a different create-before-store path and throws on invalid input; substituting it
would lose the synchronous initializer coverage. These contexts apply only to the three named test declarations,
with their names, complete bodies, and assertions preserved. They do not authorize suite/file annotations, compiler
warning flags, suppression directives, disabled traits, production annotation changes, or compatibility shims.

An audited, dependency-free fixture importing only `Testing` confirmed on Xcode 27 / Swift 6.4 that all three annotated
tests were discovered and passed, including the two actor-isolated cases, with zero skips or warnings. That toy runtime
proof establishes framework semantics only. Compile-only qualification of the real owners does not execute these
contracts: all three real tests still require hosted/isolated execution. Revalidate discovery and execution when changing
the context or toolchain; remove this exception only with an explicitly approved migration of the released contracts.
