#!/bin/bash
# Fail-closed validator for the canonical PROJECT_BRIEF.json artifact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIEF="${1:-}"
EXPECTED_VERSION=""
shift || true
for arg in "$@"; do
  case "$arg" in
    --expected-version=*) EXPECTED_VERSION="${arg#*=}" ;;
    *) echo "brief-validator: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ -z "$EXPECTED_VERSION" ] && [ -f "$SCRIPT_DIR/../VERSION" ] && [ ! -L "$SCRIPT_DIR/../VERSION" ]; then
  EXPECTED_VERSION="$(tr -d '\r\n' < "$SCRIPT_DIR/../VERSION")"
fi
[ -n "$BRIEF" ] && [ -n "$EXPECTED_VERSION" ] \
  || { echo "brief-validator: PROJECT_BRIEF.json path and expected version are required" >&2; exit 2; }
[ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] \
  || { echo "brief-validator: PROJECT_BRIEF.json is missing or unsafe" >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
  || { echo "brief-validator: jq is required" >&2; exit 2; }
command -v cmp >/dev/null 2>&1 \
  || { echo "brief-validator: cmp is required" >&2; exit 2; }

tmp="$(mktemp)" || { echo "brief-validator: could not create temporary file" >&2; exit 2; }
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM

jq -e --arg version "$EXPECTED_VERSION" '
  def nonblank: type == "string" and test("[^[:space:]]");
  def valid_date:
    capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})$") as $x
    | ($x.y|tonumber) as $y | ($x.m|tonumber) as $m | ($x.d|tonumber) as $d
    | ($m >= 1 and $m <= 12 and $d >= 1
       and $d <= ([31,(if (($y%4==0 and $y%100!=0) or $y%400==0) then 29 else 28 end),31,30,31,30,31,31,30,31,30,31][$m-1]));
  def pointer_path:
    split("/")[1:] | map(gsub("~1"; "/") | gsub("~0"; "~"));
  def allowed_pointer:
    IN(
      "/schema_version", "/advisory", "/generated_by", "/source_version",
      "/captured_from_git_rev", "/template_manifest_digest", "/detected_type",
      "/goal", "/success_criteria", "/cadence", "/deadline", "/stack",
      "/test_framework", "/secrets_handling", "/external_network", "/prohibitions",
      "/initial_project_state", "/initial_project_state/is_git_repo",
      "/initial_project_state/has_existing_tests",
      "/initial_project_state/existing_harness_files",
      "/initial_project_state/detection_summary", "/operation_preferences",
      "/operation_preferences/commit", "/operation_preferences/push",
      "/operation_preferences/merge", "/operation_preferences/release",
      "/operation_preferences/install_packages",
      "/operation_preferences/external_mutation",
      "/operation_preferences/destructive_ops", "/defaults_applied",
      "/conflicts_resolved", "/type_evidence", "/provenance"
    );
  def default_pointer:
    IN(
      "/cadence", "/deadline", "/secrets_handling", "/external_network",
      "/prohibitions", "/operation_preferences",
      "/operation_preferences/commit", "/operation_preferences/push",
      "/operation_preferences/merge", "/operation_preferences/release",
      "/operation_preferences/install_packages",
      "/operation_preferences/external_mutation",
      "/operation_preferences/destructive_ops", "/goal", "/success_criteria"
    );
  def conflict_pointer:
    IN(
      "/detected_type", "/goal", "/success_criteria", "/cadence", "/deadline",
      "/stack", "/test_framework", "/secrets_handling", "/external_network",
      "/prohibitions", "/initial_project_state/is_git_repo",
      "/initial_project_state/has_existing_tests",
      "/initial_project_state/existing_harness_files",
      "/initial_project_state/detection_summary",
      "/operation_preferences/commit", "/operation_preferences/push",
      "/operation_preferences/merge", "/operation_preferences/release",
      "/operation_preferences/install_packages",
      "/operation_preferences/external_mutation",
      "/operation_preferences/destructive_ops"
    );
  def execution_critical_pointer:
    IN("/goal", "/success_criteria", "/detected_type", "/initial_project_state/is_git_repo");
  . as $brief
  | type == "object"
  and (keys | sort == [
    "advisory","cadence","captured_from_git_rev","conflicts_resolved",
    "deadline","defaults_applied","detected_type","external_network",
    "generated_by","goal","initial_project_state","operation_preferences",
    "prohibitions","provenance","schema_version","secrets_handling",
    "source_version","stack","success_criteria","template_manifest_digest",
    "test_framework","type_evidence"
  ])
  and .schema_version == 1
  and .advisory == true
  and .generated_by == ("harness-companion v" + $version)
  and .source_version == $version
  and (.captured_from_git_rev == null or
       (.captured_from_git_rev | type == "string" and test("^[0-9a-f]{40}$")))
  and (.template_manifest_digest | type == "string" and test("^[0-9a-f]{64}$"))
  and (.detected_type | IN("node","python","rust","go","shell","electron","mixed","docs","unknown"))
  and (.goal | nonblank and length <= 500)
  and (.success_criteria | type == "array" and length >= 1 and length <= 7
       and all(.[]; nonblank and length <= 500))
  and (.cadence | IN("stable","weekly","daily","oneoff"))
  and (.deadline == null or (.deadline | type == "string" and valid_date))
  and (.stack | IN("node","python","rust","go","shell","electron","mixed","docs","unknown"))
  and (.test_framework | type == "string" and length > 0 and length <= 50)
  and (.secrets_handling | IN("env-file","vault","keyring","unspecified"))
  and (.external_network | IN("ask","allowed","denied"))
  and (.prohibitions | type == "array" and length <= 20
       and all(.[]; nonblank and length <= 200))
  and (.initial_project_state | type == "object"
       and (keys | sort == ["detection_summary","existing_harness_files","has_existing_tests","is_git_repo"])
       and (.is_git_repo | type == "boolean")
       and (.has_existing_tests | type == "boolean")
       and (.existing_harness_files | type == "array" and all(.[]; type == "string"))
       and (.detection_summary | type == "string" and length <= 200))
  and (.operation_preferences | type == "object"
       and (keys | sort == ["commit","destructive_ops","external_mutation","install_packages","merge","push","release"])
       and all([.commit,.push,.merge,.release,.install_packages,.external_mutation][];
         IN("ask","auto","denied"))
       and (.destructive_ops | type == "boolean"))
  and (.defaults_applied | type == "array"
       and ([.[].field] | unique | length) == length
       and all(.[]; . as $default |
         type == "object" and (keys | sort == ["field","rationale","source","value"])
         and ($default.field | type == "string" and startswith("/") and default_pointer)
         and ($default.rationale | nonblank and length <= 200)
         and ($default.source | IN("spec_default","legacy_placeholder"))
         and $default.value == ($brief | getpath($default.field | pointer_path))))
  and (.conflicts_resolved | type == "array"
       and all(.[]; . as $conflict |
         type == "object"
         and (keys | sort == ["field","repo_evidence","resolution","resolved_value","user_input"])
         and ($conflict.field | type == "string" and startswith("/") and conflict_pointer)
         and ($conflict.repo_evidence | type == "string")
         and ($conflict.user_input | type == "string")
         and ($conflict.resolution | IN("user","repo","custom","deferred"))
         and (if $conflict.resolution == "deferred"
              then ($conflict.field | execution_critical_pointer | not)
              else true end)
         and (if $conflict.resolution == "deferred" then $conflict.resolved_value == null
              else $conflict.resolved_value != null
                and $conflict.resolved_value == ($brief | getpath($conflict.field | pointer_path)) end)))
  and (if (.detected_type | IN("mixed","unknown")) then
         (.type_evidence | type == "object"
          and (keys | sort == ["markers_seen","notes"])
          and (.markers_seen | type == "array" and all(.[]; type == "string"))
          and (.notes | type == "string" and length <= 500))
       else .type_evidence == null end)
  and (.provenance | type == "object"
       and all(to_entries[]; . as $entry |
         ($entry.key | startswith("/") and allowed_pointer)
         and ($entry.value | type == "object")
         and ($entry.value.source | IN("conversation","repo","environment","cli","spec_default","legacy_placeholder","existing_brief"))
         and (if $entry.value.source == "repo" then
                ($entry.value | keys | sort | IN(["source"],["marker","source"]))
                and (($entry.value | has("marker") | not) or ($entry.value.marker | nonblank))
              else ($entry.value | keys) == ["source"] end)
         and (($brief | getpath($entry.key | pointer_path)) != null or
              ($entry.key | IN("/deadline","/type_evidence")))
         and (if ($entry.value.source | IN("spec_default","legacy_placeholder")) then
                any($brief.defaults_applied[];
                  .field == $entry.key and .source == $entry.value.source)
              else true end)))
' "$BRIEF" >/dev/null 2>&1 \
  || { echo "brief-validator: canonical schema validation failed" >&2; exit 1; }

jq -S . "$BRIEF" > "$tmp" \
  || { echo "brief-validator: canonical serialization failed" >&2; exit 1; }
cmp -s -- "$BRIEF" "$tmp" \
  || { echo "brief-validator: JSON is not in canonical sorted LF form" >&2; exit 1; }
