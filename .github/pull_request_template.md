<!--
Optional linked context:
Add a visible `Closes #<issue-number>` or `Related: #<issue-number>` line
below this comment.

Write for someone who uses Peekaboo but has not read the code. The title and
opening problem statement should make sense without the diff or linked issue.

Use the repository's Conventional Commit title format:
type: <what changes for the person affected>
Types: feat, fix, chore, docs, test, refactor, build, ci, style, perf.
Use a parenthesized scope only when it helps that reader.

Name the affected task and the symptom or outcome, not the implementation.
Illustrative wording, not claims about current bugs:
Good: fix: keep typing in the selected window when another app opens
Bad: fix(input): guard the target PID during event dispatch
Good: docs: explain which app needs screen capture permission
Bad: docs(tcc): document permission-source resolution

For internal-only work, name the actual developer or operator workflow affected.
-->

## What Problem This Solves

<!--
Describe the concrete user, product, or operational problem.
In 1–3 short, plain-language sentences, explain what someone is trying to do,
what goes wrong or is missing, and why it matters. For a fix, include the trigger
when known. For other changes, describe the need without inventing a bug.

Illustrative wording, not a report of a current bug:
Good: "While typing into a selected window, opening another app can send the
remaining text to the wrong place."
Bad: "Fixes target-process validation during keyboard event dispatch."

Describe the experienced problem, not just the code change. Save function names,
missing checks, and the root-cause walkthrough for the explanation below.
-->

## User Impact

<!--
"User impact: <what users, operators, or developers can now do or expect>."
Lead with the concrete outcome in plain language, usually one sentence.
For internal-only changes, say there is no user-visible change; do not invent a benefit.
Keep important risks, breaking changes, migrations, and required user actions visible here.
-->

## Why This Change Was Made

<!--
Briefly explain how the change addresses the problem without repeating the impact.
Mention related documentation updates, or say when none are needed.
Keep the body short. Leave file lists, internal acronyms, and root-cause walkthroughs
in the diff or optional <details>; include technical detail only when it explains
behavior or a material tradeoff. Do not hide risks or required actions in <details>.
-->

## Evidence

<!--
Start with the behavior checked and the result in plain language. Reviewers will
inspect the code, tests, and CI; do not make them decode command lists to learn
what was verified. Keep the useful evidence summary and meaningful gaps visible.

Use proof appropriate to the change: focused tests, CI results, live observations,
screenshots, terminal output, or artifact links. For behavior changes, include
screenshots or terminal snippets as described in AGENTS.md. Redact private screen
content, credentials, and other sensitive data before sharing evidence.

List the test commands executed. Put exact commands, commit hashes, and long
output in links or optional <details>, after the result summary. State what was
not checked and why; do not present hypothetical examples as verified behavior.
-->
