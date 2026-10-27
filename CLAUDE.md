# CLAUDE.md — Quick Reference

`AGENTS.md` is the operating manual for this repository; read it first. This
file exists because the harness knowledge subsystem expects a `CLAUDE.md` next
to `AGENTS.md`, and it deliberately carries no independent rules. (The generic
scaffold that this project ships to *target* projects lives in
`templates/CLAUDE.md`; do not confuse the two.)

## Commands

```bash
bash init.sh                 # project self-check (fail-closed)
bash tests/run-all.sh        # full suite (~60-90 min on Windows)
```

```powershell
./dsh/acceptance.ps1         # DSH acceptance: 7 scenarios, ~1 min
./dsh/install.ps1            # install into %DSH_HOME%\skills
./dsh/smoke.ps1              # installed-skill smoke: 9 checks
```

## Layout

- `dsh/` — the only host runtime (launcher, installer, smoke, acceptance)
- `core/` — POSIX bash semantics (status, feature, verify, audit)
- `scripts/` — init executor, handoff, consent boundary
- `templates/` — scaffolding shipped to target projects
- `references/` — file formats, subsystem mapping, conversation rules
- `tests/` — core / bootstrap / init / release suites, acceptance evidence

## Conventions

- Business semantics stay in `core/`; host mapping stays in `dsh/`.
- Never hand-craft NDJSON run logs; generate them with `core/harness-verify.sh`.
- WIP=1, evidence before `passing`, fail-closed init.

## See also

`AGENTS.md` (authoritative), `README.md`, `CHANGELOG.md`,
`docs/acceptance/2026-10-27-dsh-2.0.0.md`.
