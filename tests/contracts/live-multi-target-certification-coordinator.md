# Live Multi-Target Coordinator Behavior Contract

## User-Visible Goal

Run one fresh, owner-private certification lifecycle with exactly two persistent background controllers, one
observe-only semantic witness, one source-pinned monitor, and a bounded two-phase external Computer Use window. A
persisted summary is never itself certification authority; only the final live finalizer exit may complete the run.

## Target

- Type: CLI
- Launch: `node scripts/run-live-multi-target-certification.mjs --plan OWNER_PRIVATE_PLAN.json`
- Fixtures: owner-private fake child executables and files may exercise lifecycle behavior, but test-runtime output must
  be explicitly ineligible for certification.

## User Tasks

1. Start a valid run and observe a fresh nonce, monitor UUID, and newly created private run root.
2. Wait for the `perform` external-foreground event, carry out the named task, and publish the closed task marker.
3. Wait for the `restore` external-foreground event, restore the exact semantic baseline and sentinel, and publish the
   closed restoration marker.
4. Observe both controllers and the semantic observer remain alive through monitor sealing, PID-bound challenges,
   prepare, and final finalization, then exit only after their owner release markers.

## Expected Observable Behavior

- The plan schema is closed. Unknown fields, non-private inputs, wrong target/controller cardinality, and unbounded
  timeouts fail before child launch.
- Crash evidence comes only from the canonical current user's `~/Library/Logs/DiagnosticReports`; its closed prefix
  set includes `Playground`, the signed fixture's resolved executable and diagnostic-report basename, while preserving
  the legacy `PeekabooPlayground` watch entry. An empty substitute, alias, or symlink is not accepted as a quieter
  evidence source.
- An eligible run derives its current-build commit from a clean Git HEAD. The controller executable, Peekaboo
  validator, expected Bridge host, signed controller receipts, and observe-only witness build must all carry that same
  commit; no catalog literal can stand in for it.
- External markers are accepted only for the fresh execution nonce, monitor instance, and exact requested phase.
- Baseline, grant, operations-start, operations-complete, revoke, and final fences are strictly ordered stable monitor
  heartbeats. Their safe-integer monotonic microseconds strictly increase, wall-clock milliseconds never decrease, and
  adjacent clock deltas remain within two seconds. Foreground activity is absent except at operations-complete, where
  it belongs to the exact integrated Computer Use producer PID.
- Both controller mutation intervals remain open across operations-start and operations-complete.
- Each controller publishes a process-bound non-final readiness marker, and neither may begin its final-bounds capture
  until the coordinator has validated both markers and released both owner-private barriers.
- Monitor sealing and monitor/observer challenges bind the live PIDs and exact evidence bytes. Caller-written success
  or certification fields are never accepted. Each attester remains alive after publishing its response and exits only
  after the coordinator writes its owner-private release marker.
- The coordinator retains the verified finalizer bytes before the live run, executes those exact bytes for both phases,
  grants `prepare` exclusive ownership of a previously absent artifact root, and derives its outer deadline from all
  eight bounded bundle validations plus identity/runtime overhead for each of the two serialized invocations.
- Failure performs bounded release/TERM/KILL cleanup while preserving the private run root for diagnosis.
- Test-runtime completion is reported as `test-runtime-complete` with `certification_eligible: false`.

## Anti-Cheat Probes

- Add an unknown plan field.
- Replay an external marker with a different nonce or phase.
- Exit one controller before release.
- Emit a monitor fence with a replayed sequence/epoch, wrong producer revision, contamination, or caller activity at
  the wrong fence.
- Preserve finite fractional logical coordinates; emit nonfinite or negative-zero geometry, or a wall/monotonic fence
  drift greater than two seconds.
- Return a sealed corpus or PID-attestation digest that differs from the exact evidence bytes.
- Attempt to reuse a nonempty or non-private run input.
- Dirty the checkout, drift a source-manifest file, substitute a differently stamped executable, or inject a current
  commit literal into the acyclic catalog descriptor.

## Evidence Required

- JSON lifecycle events from stdout, exit status, fake-child invocation log, preserved run-root file inventory, and
  finalizer invocation log.

## Out Of Scope

- Physical UI operation, TCC, AppleScript/JXA, virtualization, and fixture-based certification success.
