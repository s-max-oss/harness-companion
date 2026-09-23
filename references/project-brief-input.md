# Project Brief executor input contract

Read this reference before constructing the first JSON payload for
`harness-init-boundary.sh`. The boundary is not a schema-discovery mechanism:
do not send a guessed payload, inspect its error, and retry.

Use this exact top-level vocabulary for a complete guided Brief:

```json
{
  "schema_version": 1,
  "goal": "<exact approved goal>",
  "success_criteria": ["<each exact approved criterion>"],
  "detected_type": "python",
  "stack": "python",
  "test_framework": "pytest",
  "cadence": "stable",
  "deadline": null,
  "secrets_handling": "unspecified",
  "external_network": "ask",
  "prohibitions": [],
  "initial_project_state": {
    "is_git_repo": false,
    "has_existing_tests": false,
    "existing_harness_files": [],
    "detection_summary": "<short repository observation>"
  },
  "operation_preferences": {
    "commit": "ask",
    "push": "ask",
    "merge": "ask",
    "release": "ask",
    "install_packages": "ask",
    "external_mutation": "ask",
    "destructive_ops": false
  },
  "defaults_applied": [
    {
      "field": "/cadence",
      "value": "stable",
      "rationale": "<why this documented default applies>",
      "source": "spec_default"
    }
  ],
  "conflicts_resolved": [],
  "type_evidence": null,
  "provenance": {
    "/goal": {"source": "conversation"},
    "/success_criteria": {"source": "conversation"}
  }
}
```

Replace the example values with the confirmed values; preserve the field names
and shapes. In particular:

- `goal` is a non-empty string of at most 500 characters.
  `success_criteria` is an array of one to seven non-empty strings.
- `detected_type` and `stack` each use exactly one of `node`, `python`, `rust`,
  `go`, `shell`, `electron`, `mixed`, `docs`, or `unknown`.
- `test_framework` is a non-empty string of at most 50 characters. Use the
  repository's canonical identifier (for example `pytest`, `jest`, or `none`),
  not a display-name variant.
- `cadence` is one of `stable`, `weekly`, `daily`, or `oneoff`. `deadline` is
  `null` or a real `YYYY-MM-DD` date. `secrets_handling` is one of `env-file`,
  `vault`, `keyring`, or `unspecified`. `external_network` is one of `ask`,
  `allowed`, or `denied`. `prohibitions` is an array of at most 20 non-empty
  strings, each at most 200 characters.
- Use `detected_type`, not `project_type`.
- Use top-level `secrets_handling`, `external_network`, and `prohibitions`; do
  not wrap them in `constraints`.
- Use `initial_project_state`, not `initial_state`. Its exact member names are
  `is_git_repo`, `has_existing_tests`, `existing_harness_files`, and
  `detection_summary`. Keep `detection_summary` to one concise repository
  observation of at most 200 characters; optional product choices belong in
  the conversation, not in this field.
- `initial_project_state.has_existing_tests` records testing markers, not a
  verified test inventory or a passing test run. Under this contract, any of
  `pytest.ini`, `pyproject.toml [tool.pytest]`, `Cargo.toml`, `go.mod` with test
  files, `package.json scripts.test`, `Makefile`, or `*.bats` is sufficient
  repository evidence for `true`. For example, pytest configuration is
  sufficient even if no test files are present; describe that limitation in
  `detection_summary`, without running tests during initialization. Do not copy
  the example's `false` or infer present state from a desired success criterion.
- The exact operation member names are `commit`, `push`, `merge`, `release`,
  `install_packages`, `external_mutation`, and `destructive_ops`. The first six
  each use exactly `ask`, `auto`, or `denied`; `destructive_ops` is a boolean.
- Each `defaults_applied` item uses `field`, `value`, `rationale`, and `source`;
  it never uses `path`.
- `provenance` is an object keyed by JSON pointers, not an array. Its `source`
  is one of `conversation`, `repo`, `environment`, `cli`, `spec_default`,
  `legacy_placeholder`, or `existing_brief`.
- `conflicts_resolved` items, when present, use exactly `field`,
  `repo_evidence`, `user_input`, `resolution`, and `resolved_value`. The first
  three are strings; `field` is a supported Brief JSON pointer. `resolution`
  is exactly one of `user`, `repo`, `custom`, or `deferred`. A deferred item
  has `resolved_value: null`; every other resolution has a non-null value.
  Execution-critical conflicts (`/goal`, `/success_criteria`,
  `/detected_type`, and `/initial_project_state/is_git_repo`) cannot be
  deferred. Example:

  ```json
  {
    "field": "/external_network",
    "repo_evidence": "The existing policy denies outbound access.",
    "user_input": "Keep network access disabled.",
    "resolution": "user",
    "resolved_value": "denied"
  }
  ```

  Supported conflict pointers are `/detected_type`, `/goal`,
  `/success_criteria`, `/cadence`, `/deadline`, `/stack`, `/test_framework`,
  `/secrets_handling`, `/external_network`, `/prohibitions`, each of the four
  `/initial_project_state/<member>` pointers listed above, and each of the
  seven `/operation_preferences/<member>` pointers listed above.

- `type_evidence` is required for `mixed` or `unknown` and contains
  `markers_seen` (an array of strings) plus `notes` (a string of at most 500
  characters); it may be `null` for a known type. Example:

  ```json
  {
    "markers_seen": ["package.json", "pyproject.toml"],
    "notes": "Both Node and Python project markers are present."
  }
  ```

- Do not add top-level `constraints`, `initial_state`, `project_type`,
  `deferred`, or other guessed compatibility aliases. Optional product choices
  stay conversationally deferred; provenance may record them under
  `/deferred/<name>` when useful.

The executable validation in `scripts/harness-init.sh` remains authoritative.
If this reference and that validator disagree, stop before invoking the
boundary and report the contract mismatch.

Before presenting the complete Brief for approval, run a read-only preflight
by piping the exact compact JSON to:

```text
scripts/harness-init.sh <existing-target> --brief-stdin --validate-brief-only --non-interactive --host=<claude|codex>
```

This path returns `{"valid":true}` without staging or writing target files; it
is not the mutation boundary and does not count as approval or initialization.
Present and later execute that same validated Brief. If validation fails,
correct an unconfirmed representation or ask the user about any semantic
change before presenting it; never discover a schema error for the first time
at the approved mutation boundary.
