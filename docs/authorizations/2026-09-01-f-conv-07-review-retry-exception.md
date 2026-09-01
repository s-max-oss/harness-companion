# F-CONV-07 Reviewer retry exception

Date: 2026-09-01

The user explicitly authorized a one-time scope exception after the Phase 3
cumulative Reviewer found that the F-CONV-07 per-feature PASS was recorded as
attempt 7, beyond `.harness/PLAN.json`'s five-retry limit.

This authorization does not rewrite the frozen Plan or any prior verdict. It
permits exactly one new, append-only F-CONV-07 per-feature review after the
following conditions are met:

1. the missing-GNU-`timeout` fail-open defect is fixed and covered by negative
   tests;
2. the fresh Reviewer examines the full cumulative feature diff from
   `bd57935252120bb44d1b43de3623c1fe3f0a46a9` to the new HEAD;
3. the verdict is appended as the next attempt and binds valid current-HEAD
   verification evidence;
4. a separate fresh cumulative Phase 3 Reviewer still runs afterward.

The exception does not authorize deleting, truncating, renumbering, or
rewriting attempts 1–7, weakening any acceptance gate, or reusing a previous
Reviewer conclusion. It does not change the retry policy for any other feature
or phase.
