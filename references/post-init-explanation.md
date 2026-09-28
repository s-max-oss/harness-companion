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
If the next step includes `/harness:init`, introduce it as the
confirmation-based setup command rather than calling it "guided" without an
explanation.

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

Account for every entry in the confirmed Brief's `defaults_applied` array. Use
that array as the outline: draft a plain-language clause for each recorded
value, then combine related clauses into natural sentences without losing
any entry. For initial completion, compare the finished explanation back to
the array: identify the clause that communicates each recorded value. If an
entry has no corresponding clause, add its practical meaning before sending.
Disclosure in the earlier approval Brief does not fill a gap in this
post-write explanation. This is a composing check, not another user question
or a reason to rerun the executor. For a later Brief update, use "Explain a
post-init update" below.

- Briefly explain each value's practical effect when the name alone is unclear.
- Do not describe an explicit user choice as a default.
- Empty arrays, nulls, and false values still describe accepted decisions;
  they are not entries to skip. For example, `prohibitions: []` means no
  additional project-specific prohibitions were specified, not that every action is
  authorized. A null deadline means no deadline was set.
- When grouping operation preferences, name the operations covered by each
  permission requirement and distinguish disabled actions; an undefined label
  such as "consequential operations" does not communicate which actions need permission.
- Do not report product or implementation choices as defaults unless they were
  explicitly supplied by the user and represented in the executed Brief.

Example when the confirmed Brief accepted all documented defaults (omit or
adapt any clause that was not actually defaulted in this run):

> I used a stable delivery cadence, left the deadline and credential-handling
> method unspecified, and recorded no additional project-specific prohibitions.
> Outside-network access, commits, pushes, merges, releases, package installation,
> and other external changes still require permission; destructive actions are
> disabled. You can refine the credential-handling method before adding credentials.

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
Defaulted: <all actually accepted defaults, grouped naturally + practical effect>.
Deferred: <optional unresolved decisions + how to refine them>.

<one or two revisitable decisions and the natural next step>
```

Always cover all four categories. Keep an empty category to a short, natural
statement such as "No values were inferred," "No defaults were needed," or
"Nothing remains undecided." **Generated** always summarizes the successful
filesystem outcome. The final response should read like an explanation to the
project owner, not an audit report.
