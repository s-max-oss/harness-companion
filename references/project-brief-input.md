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

- Use `detected_type`, not `project_type`.
- Use top-level `secrets_handling`, `external_network`, and `prohibitions`; do
  not wrap them in `constraints`.
- Use `initial_project_state`, not `initial_state`. Its exact member names are
  `is_git_repo`, `has_existing_tests`, `existing_harness_files`, and
  `detection_summary`.
- The exact operation member names are `commit`, `push`, `merge`, `release`,
  `install_packages`, `external_mutation`, and `destructive_ops`.
- Each `defaults_applied` item uses `field`, `value`, `rationale`, and `source`;
  it never uses `path`.
- `provenance` is an object keyed by JSON pointers, not an array. Its `source`
  is one of `conversation`, `repo`, `environment`, `cli`, `spec_default`,
  `legacy_placeholder`, or `existing_brief`.
- `conflicts_resolved` items, when present, use exactly `field`,
  `repo_evidence`, `user_input`, `resolution`, and `resolved_value`.
- `type_evidence` is required for `mixed` or `unknown` and contains
  `markers_seen` plus `notes`; it may be `null` for a known type.
- Do not add top-level `constraints`, `initial_state`, `project_type`,
  `deferred`, or other guessed compatibility aliases. Optional product choices
  stay conversationally deferred; provenance may record them under
  `/deferred/<name>` when useful.

The executable validation in `scripts/harness-init.sh` remains authoritative.
If this reference and that validator disagree, stop before invoking the
boundary and report the contract mismatch.
