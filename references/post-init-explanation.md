# Post-init explanation

Load this reference only when `/harness:init` is invoked. Use it after the
executor succeeds so the user can understand the result without opening the
Brief JSON or reading a file manifest.

## Explain the outcome, not the machinery

Start with one plain-language sentence confirming that initialization
completed. Then explain the result in four categories: **generated**,
**inferred**, **defaulted**, and **deferred**. Keep the explanation
conversational and proportional to the run. Do not dump JSON, enumerate schema
fields mechanically, or narrate internal Harness validation steps.

If the user signaled that the setup or its terminology was unfamiliar, keep
novice-language mode active in this final response. Avoid internal labels such
as `snapshot` or `run-log directory`, or immediately explain them in terms of
what they do. Apply the same rule to product terms such as `framework`: call it
the toolkit used to build the app unless the technical label genuinely helps.

Use only facts from the confirmed Brief, repository evidence, executor result,
and post-init file state. Do not claim that a file was created when it was
preserved, or that a value was inferred when it came from a default.

Before sending the explanation, reconcile three views: the human Brief the
user approved, the exact machine-readable Brief passed to the executor, and
the resulting `PROJECT_BRIEF.json`. They must describe the same decisions. If
the approved presentation contained a choice that the executed Brief could
not represent, treat that as a failed consent boundary rather than presenting
initialization as fully successful. Never silently drop the choice.

## Generated

Summarize what the executor actually created or updated.

- Give a useful count and name the important outputs, such as the rendered
  project Brief, Harness configuration, feature registry, agent instructions,
  initialization script, and host-specific progress file.
- Distinguish newly created, updated, and preserved files when re-entering an
  initialized project.
- Mention full-mode handoff/checklist files only when that run produced them.
- If `.gitignore` was extended, describe it as an append; never imply that the
  user's existing entries were replaced.
- Prefer a compact summary over a complete path dump. Offer the detailed list
  only when it would help the user.

Example:

> Initialization is complete. I created the project Brief and Harness
> configuration, added the feature registry and agent guidance, and prepared
> the initialization and progress files. Your existing `.gitignore` content
> was preserved; the Harness runtime entries were appended.

## Inferred

Explain decisions derived from repository evidence rather than supplied
directly by the user.

- Name the inferred value and the evidence that supports it, using a short
  path or recognizable file name.
- Include only decisions that affected the generated result or are useful for
  understanding it.
- Keep source attribution visible so the user can correct a mistaken
  inference.

Example:

> I detected a Python project from `pyproject.toml` and selected pytest because
> the repository contains `pytest.ini`.

## Defaulted

Call out meaningful values that neither the user nor repository evidence
resolved and for which the confirmed Brief accepted a default.

- State the selected value in plain language.
- Briefly explain its practical effect when the name alone is unclear.
- Prioritize defaults the user may reasonably want to revisit, such as
  delivery cadence or secret-handling strategy.
- Do not describe an explicit user choice as a default.
- Account for every entry in the confirmed Brief's `defaults_applied` array,
  grouping related operation preferences in one sentence when useful. Do not
  replace the actual list with a selective summary that omits values such as
  a null deadline.
- Do not report product or implementation choices as defaults unless they were
  explicitly supplied by the user and represented in the executed Brief.

Example:

> I used the stable delivery cadence and left secret handling unspecified.
> That is safe for setup, but you may want to choose an environment file,
> vault, or keyring before adding credentials.

## Deferred

List optional decisions that remain unresolved after the confirmed Brief.

- Say what is undecided and whether it blocks any current work.
- Keep optional product and implementation decisions here when no documented,
  machine-representable Brief default resolves them. A request for “sensible
  defaults” does not by itself choose a framework, database, UI architecture,
  authentication, or deployment approach.
- Never label an execution-critical conflict as deferred. `goal`,
  `success_criteria`, the primary-stack `detected_type`, and
  `initial_project_state.is_git_repo` must already have been resolved before a
  guided run can succeed.
- Tell the user how to refine the decision: discuss the change and rerun
  `/harness:init` in guided mode. Do not instruct them to hand-edit generated
  JSON as the normal workflow.
- When nothing was deferred, keep the category and say so naturally, for
  example: "Nothing remains undecided."

Example:

> The release deadline is still undecided, and it does not block the current
> setup. When you choose one, rerun `/harness:init` and I will update the Brief.

## Highlight revisitable decisions

After the four categories, mention at most the few decisions most likely to
benefit from review. Base this on the actual run: uncertain inferences,
consequential defaults, and deferred optional fields. Invite correction
without reopening already confirmed questions.

Close with a natural next step, for example:

> The setup is ready. If any inferred or defaulted choice looks wrong, tell me
> what to change and I can rerun guided init safely.

This closing step is required after every successful guided initialization.
When decisions are deferred, explicitly say that the user can discuss those
choices and rerun `/harness:init`; when nothing is deferred, still invite the
user to correct any revisitable inference or default. A generated/inferred/
defaulted/deferred summary without this route forward is incomplete.

Do not continue asking questions merely to keep the conversation active.
Resume dialog only for new authorization, an information conflict, a scope
change, a real blocker, or completion of a major phase.

## Explain a post-init update

When the user changes the Brief after initialization, rerun the executor through
its resume/update path. The executor's three-way SHA comparison protects
user-modified files. After a successful update:

1. State which Brief decisions changed.
2. State which generated files were updated.
3. State which files were preserved, especially user-modified files.
4. Keep all four categories. Give detail where values changed or remain
   important, and describe unchanged or empty categories in one short phrase.

Name every generated file that the successful executor result reports as
updated, using its repository-relative path (for example,
`.harness/PROJECT_BRIEF.json` and `.harness/PROJECT_BRIEF.md`). A generic claim
such as "the Brief was updated" does not satisfy this step. Likewise, distinguish
files actually updated from files merely inspected or preserved.

Never promise that a file was preserved unless the executor result and
post-init state establish that fact. If a three-way conflict or another real
blocker prevents the update, explain the blocker instead of presenting a
success summary.

## Compact response shape

Adapt the wording rather than reciting this verbatim:

```text
Initialization is complete.

Generated: <important created/updated outputs; preserved files when relevant>.
Inferred: <decision from repository evidence + source>.
Defaulted: <meaningful accepted defaults + practical effect>.
Deferred: <optional unresolved decisions + how to refine them>.

<one or two revisitable decisions and the natural next step>
```

Always cover all four categories. Keep an empty category to a short, natural
statement such as "No values were inferred," "No defaults were needed," or
"Nothing remains undecided." **Generated** always summarizes the successful
filesystem outcome. The final response should read like an explanation to the
project owner, not an audit report.
