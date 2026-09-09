# Conversational forward evaluation

F-CONV-08 exercises `/harness:init` through a real Claude Code or Codex
conversation. The subject Agent gets the checked-in `SKILL.md`, a minimal
isolated runtime copy, repository evidence from a disposable fixture, and the
case's scripted user turns. It does not receive the expected signals, rubric,
specification text, or prior eval results.

The release path is intentionally split into two processes. The Agent runner
has no signing key and may only publish an unsigned candidate. After every
Agent and Reviewer process has exited, a separate controller validates that
candidate and signs the promoted result.

Run one case from the repository root on native Windows:

```bash
bash tests/eval/run-eval.sh tests/eval/cases/vague-goal.json \
  --agent=codex --reviewer=codex \
  --model=gpt-5.6-sol --reviewer-model=gpt-5.6-sol
```

The command writes under `tests/eval/candidates/`. Do not provide
`HARNESS_EVAL_SIGNING_KEY`; the runner fails closed if signing material is
present. A real release-eligible run currently requires Codex in its native
Windows elevated sandbox. ACLs deny both Codex sandbox accounts access to the
source workspace, controller evidence, the installed Skill authority, and
user-profile executable probes while the Agent runs. Shell commands inherit no
host profile environment; HOME, USERPROFILE, TEMP, TMP, APPDATA, and
LOCALAPPDATA point at the disposable run scratch, and the real host temp root
is explicitly write-denied to both Codex sandbox identities.
Only a minimal Skill copy and disposable target are visible. A real Claude run
is refused until an equivalent external OS/container boundary is available.

After the runner exits, attest its exact candidate from a separate process:

```bash
bash tests/eval/attest-result.sh \
  tests/eval/candidates/vague-goal.1.<timestamp>.json \
  --signing-key=/path/to/local/release-key
```

The public half of that local Ed25519 key must be authorized by
`tests/eval/trust/release-allowed-signers`; the private key must never be
committed or exposed to an Agent process. With the production trust anchor the
attester accepts keys only below the protected source workspace and outside
the product repository; the eval ACL denies that workspace to sandbox
accounts. The attester revalidates every
authority and evidence hash, promotes the result, then signs it in the
`harness-eval` SSH signature namespace. The gate verifies that detached
attestation against the checked-in public anchor, so self-reported booleans and
hashes cannot promote fake output.

Synthetic plumbing accepts `codex` or `claude`. The real release subject and
Reviewer are currently Codex; another real CLI is refused until it has an
equivalent pinned publisher/install policy. The Reviewer is a fresh,
non-persistent session with tools disabled. Every subject turn is also a new
non-persistent session reconstructed from the checked-in Skill plus recorded
prior dialog. A result passes only when all objective checks and every semantic
rubric check pass.

The runner atomically publishes an unsigned candidate plus ten bound evidence
files: dialog, final tree, raw subject and Reviewer events, per-turn trees,
evaluator actions, structured Reviewer output, objective checks, raw
`PROJECT_BRIEF.json`, and isolation evidence. A controller-owned publication
manifest binds every staged byte before publication. Recovery can idempotently
finish an interrupted bundle, but it still publishes the authoritative JSON
last and registers the complete canonical bundle in one runtime-manifest
transaction. The same protocol protects result promotion. The result binds the
current case, Skill, minimal runtime, runner, attester, isolation helper,
no-replace publisher, publication-bundle verifier, Reviewer schema, rubric, CLI
executable/version/model, and fresh session IDs by exact value or SHA-256.

Subject command evidence is default-deny. The validator accepts only statically
parseable, read-only commands with trusted executable boundaries; shell
expansion, environment injection, output options, callbacks, redirection, and
unrecognized parameters fail the result. Isolation evidence also binds the
target and controller paths to the exact same run root.

Run all versioned cases explicitly; the runner intentionally has no synthetic
or batch shortcut:

```bash
for case in tests/eval/cases/*.json; do
  bash tests/eval/run-eval.sh "$case" --agent=codex --reviewer=codex \
    --model=gpt-5.6-sol --reviewer-model=gpt-5.6-sol || exit 1
  candidate="$(find tests/eval/candidates -maxdepth 1 -type f \
    -name "$(jq -r .name "$case").$(jq -r .version "$case").*.json" \
    ! -name '*.reviewer-output.json' ! -name '*.project-brief.json' \
    ! -name '*.isolation.json' | LC_ALL=C sort | tail -1)"
  bash tests/eval/attest-result.sh "$candidate" \
    --signing-key=/path/to/local/release-key || exit 1
done
```

Before a tag or release, run the fail-closed gate:

```bash
bash tests/eval/check-results.sh
HARNESS_REQUIRE_EVAL_RESULTS=1 bash tests/release/test-release-archive.sh
```

The gate requires a current-version, non-synthetic, release-eligible,
`passed: true`, `CONFIRMED` result for all 14 cases and verifies all authority
and evidence bindings. CI always parses and tests the case/runner contract; tag
CI additionally activates the real-result gate.

The offline plumbing regression uses a disposable fake CLI and explicitly sets
`HARNESS_EVAL_SYNTHETIC=1`. Synthetic output is refused from the canonical
results directory and is always marked `release_eligible: false` with verdict
`SYNTHETIC`:

```bash
bash tests/eval/test-eval-contract.sh
```
