# Clean State Checklist

Before declaring a feature complete or starting a new session, verify:

## Build & Environment

- [ ] `bash init.sh` exits 0 (all dependencies installed, build passes)
- [ ] `npm run check` (typecheck) — 0 errors
- [ ] `npm run build` — exits 0
- [ ] `npm test` — all tests pass

## Feature State

- [ ] `feature_list.json` is valid JSON (`jq . feature_list.json > /dev/null`)
- [ ] All features marked `passing` have non-empty `evidence`
- [ ] No feature is stuck as `in_progress` across sessions without progress
- [ ] WIP=1: at most one feature is `in_progress`

## Progress Tracking

- [ ] `claude-progress.md` is updated with this session's work
- [ ] Session log entry includes: goal, completed, verification, commits, next step

## Repository State

- [ ] `git status` — no unexpected uncommitted changes
- [ ] All changes are committed with descriptive messages
- [ ] Branch is pushed to remote (if collaborating)

## Clean Exit

- [ ] No stale build artifacts (`dist/`, `node_modules/.cache/`, etc. are in `.gitignore`)
- [ ] Agent log has CLOSE marker (if using agent.log)
- [ ] `session-handoff.md` is updated (if using handoff)
