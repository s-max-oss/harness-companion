#!/usr/bin/env python3
"""e2_check.py — E2 tag-trigger check for CI workflows.

Contract:
  1. ONLY parses on.push.tags — no fallback to regex / other locations.
  2. Tag values MUST match the release convention (strict allowlist):
     - v*                       (catch-all v-prefixed tag)
     - v<MAJOR>.<MINOR>.<PATCH> (exact semver)
     - v<MAJOR>.<MINOR>.<PATCH>.* / .x  (patch wildcard)
     - GitHub glob: v[N]+...    (numeric bracket class)
  3. PyYAML is required — missing PyYAML = exit 2 (no regex rescue).
  4. YAML parse error = exit 11.
  5. Valid YAML but no on.push.tags (or non-release tag) = exit 10.
  6. Release tag trigger found = exit 0 (PASS).

Why a string-preserving YAML loader:
  PyYAML 1.1 (the default `SafeLoader`) coerces the bare scalars
  `on`, `off`, `yes`, `no`, `true`, `false` to Python `True`/`False`.
  GitHub Actions uses `on:` as the workflow trigger key, so under the
  default loader `data["on"]` is the boolean True — indistinguishable
  from a workflow that wrote `true:` (a fake / ambiguous trigger).
  We extend SafeLoader so those bare scalars stay as strings; only the
  YAML literal `true`/`false` keywords remain booleans. This removes
  the entire class of false-pass bugs at the loader level, instead of
  trying to recover them via a raw-text pre-check.

Usage:
  python3 e2_check.py <workflow.yml>

Exit codes:
  0  = release tag trigger detected (PASS)
  10 = valid YAML, no release trigger (NOT_FOUND)
  11 = YAML parse error (PARSE_ERR)
  2  = PyYAML missing (DEP_MISSING — fail-closed)
"""

import re
import sys


def is_release_tag(t):
    """Strict allowlist matcher for release tag patterns.

    GitHub Actions tag-pattern grammar (per GitHub Docs:
    https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet):

      | Pattern | Meaning                         | Example           |
      |---------|---------------------------------|-------------------|
      | v*      | any v-prefixed tag              | v1.2.3, vbeta     |
      | vX.Y.Z  | exact semver                    | v1.2.3            |
      | vX.Y.Z.W| 4-segment version               | v1.2.3.4          |
      | vX.Y.*  | patch wildcard                  | v1.2.*            |
      | v[0-9]+ | GitHub glob character class      | v[0-9]+.1.2.3     |

    Patterns that LOOK like GitHub globs but are not valid are rejected:
      v[0-9]bogus*   — bracket class may only contain digits, hyphens, or
                       comma-separated ranges; `bogus` is not a range.
      v[---]whatever — a bracket class of all-hyphens has no numeric anchor.
      v[              — truncated, no class body.
    """
    s = t.strip()
    if not s.startswith("v"):
        return False
    if len(s) > 64:
        return False
    if re.search(r"\s", s):
        return False
    # Validate any bracket-class segment before the global pattern runs.
    # A valid GitHub bracket class is one or more of:
    #   - single char     e.g. [0], [a]
    #   - char range      e.g. [0-9], [a-z]
    #   - comma-separated e.g. [0-9,a-z]  (commas allowed)
    # Reject malformed classes: bare hyphen (---), letters without a range
    # (`bogus`), consecutive hyphens (`-`), empty class (`[]`).
    if "[" in s:
        for m in re.finditer(r"\[([^\]]*)\]", s):
            cls = m.group(1)
            if not cls:
                return False
            # Each comma-separated item must be either a single char or a
            # char-char range. No triple-hyphens, no letters without range.
            if not re.fullmatch(
                r"(?:[A-Za-z0-9]|[A-Za-z0-9]-[A-Za-z0-9])"
                r"(?:,(?:[A-Za-z0-9]|[A-Za-z0-9]-[A-Za-z0-9]))*",
                cls,
            ):
                return False
        if s.count("[") != s.count("]"):
            return False
    # Strict allowlist — each alternative must match the ENTIRE tag string.
    # The bracket-class form is restricted to `v[N]+...` where the only
    # recognized continuation after the class is `+` (e.g. `v[0-9]+.1.2.3`),
    # NOT arbitrary trailing text like `v[0-9]bogus*`.
    RELEASE_TAG_RE = re.compile(
        r"^v("
        r"\*"
        r"|\d+\.\d+\.\d+(\.\d+)?"
        r"|\d+\.\d+\.[\*x]"
        r"|\[[\d\-,]+\]\+[^\s]*"
        r")$"
    )
    return bool(RELEASE_TAG_RE.match(s))


def _string_constructor(loader, node):
    """Coerce bare scalars to strings — except the unambiguous booleans/null.

    PyYAML 1.1 (the default SafeLoader) maps `on`, `off`, `yes`, `no`,
    `true`, `false` all to booleans, which destroys the distinction
    between a legitimate `on:` workflow trigger and a fake `true:` key.
    By intercepting the scalar constructor we keep `on:` as the string
    "on" while still honoring YAML 1.1 for the unambiguous literals
    `true`, `false`, `null`.

    Quoted strings (`"on"`, `'on'`) are unaffected — PyYAML resolves them
    via the str tag and our override returns them as strings either way.
    """
    value = loader.construct_scalar(node)
    if value == "true":
        return True
    if value == "false":
        return False
    if value == "null" or value == "~":
        return None
    # Everything else (on/off/yes/no/integers/decimals/etc.) is treated
    # as a plain string. We deliberately do NOT call
    # `construct_yaml_bool` here — that would re-introduce the bug.
    return value


def make_string_safe_loader():
    """Build a SafeLoader subclass that preserves string keys."""
    import yaml
    if not hasattr(yaml.SafeLoader, "_e2_string_keys_patched"):
        yaml.SafeLoader.add_constructor("tag:yaml.org,2002:bool", _string_constructor)
        yaml.SafeLoader.add_constructor("tag:yaml.org,2002:str", _string_constructor)
        yaml.SafeLoader.add_constructor("tag:yaml.org,2002:null", _string_constructor)
        yaml.SafeLoader._e2_string_keys_patched = True
    return yaml.SafeLoader


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: e2_check.py <workflow.yml>\n")
        sys.exit(1)

    wf_path = sys.argv[1]
    with open(wf_path, encoding="utf-8") as f:
        content = f.read()

    # PyYAML is REQUIRED. Missing dependency = fail-closed (no regex rescue).
    try:
        import yaml  # noqa: F401
    except ImportError:
        sys.stderr.write(
            "E2 FAIL: PyYAML is required for E2 tag trigger check. "
            "Install with: pip install pyyaml\n"
        )
        sys.exit(2)

    loader = make_string_safe_loader()
    try:
        data = yaml.load(content, Loader=loader)
    except yaml.YAMLError as exc:
        sys.stderr.write("E2 FAIL: YAML parse error: " + str(exc) + "\n")
        sys.exit(11)

    if not isinstance(data, dict):
        sys.stderr.write("E2 FAIL: workflow root is not a mapping\n")
        sys.exit(10)

    # ONLY look at the literal string key "on". Under the patched loader
    # this is unambiguous: a top-level `true:` key is the boolean True
    # (or the string "true" if the user quoted it), never the string
    # "on". A nested `on:` under another mapping is ignored — E2 only
    # inspects the top-level trigger.
    if "on" not in data:
        sys.stderr.write(
            "E2 FAIL: missing or invalid on: trigger block "
            "(top-level key 'on' not present)\n"
        )
        sys.exit(10)
    triggers = data["on"]
    if not isinstance(triggers, dict):
        sys.stderr.write("E2 FAIL: trigger block is not a mapping\n")
        sys.exit(10)
    push = triggers.get("push")
    if not isinstance(push, dict):
        sys.stderr.write(
            "E2 FAIL: missing or invalid push: block under on:\n"
        )
        sys.exit(10)
    tags = push.get("tags")
    if tags is None:
        sys.stderr.write("E2 FAIL: missing tags: under on.push\n")
        sys.exit(10)
    if not isinstance(tags, list):
        sys.stderr.write(
            "E2 FAIL: on.push.tags must be a list, got "
            + type(tags).__name__ + "\n"
        )
        sys.exit(10)
    if len(tags) == 0:
        sys.stderr.write("E2 FAIL: on.push.tags is empty\n")
        sys.exit(10)
    for t in tags:
        if not isinstance(t, str):
            sys.stderr.write(
                "E2 FAIL: on.push.tags entry must be a string, got "
                + type(t).__name__ + "\n"
            )
            sys.exit(10)
        if not is_release_tag(t):
            sys.stderr.write(
                "E2 FAIL: tag pattern does not match release convention: "
                + repr(t)
                + " (expected v*, vX.Y.Z, or v[N]+Y.Z glob)\n"
            )
            sys.exit(10)

    sys.exit(0)


if __name__ == "__main__":
    main()
