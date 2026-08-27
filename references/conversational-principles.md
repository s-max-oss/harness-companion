# Conversational principles for `/harness:init`

Use this reference only while handling `/harness:init`. It guides how the Agent
collects and confirms a Project Brief; it does not replace the deterministic
executor or authorize any repository mutation.

## Lead with what is already known

Before asking a question, inspect the current user message, relevant
conversation history, and repository evidence. Use them in that priority order:

1. The user's current message.
2. Earlier statements in the current conversation.
3. Repository evidence such as manifests, test configuration, source layout,
   recent Git history, and existing Harness files.

Start by briefly acknowledging useful facts already found. Do not ask the user
to repeat them. Ask only when a required Brief field is still missing after all
three sources have been considered.

Repository evidence supports inference; it does not overrule the user. Mark the
source of every Brief value so the user can see how it was obtained:

- `[from you]`
- `[inferred from <path>]`
- `[default]`
- `[to decide]`

## Conduct a dialog, not a questionnaire

The Agent drives the conversation and makes the next useful step obvious.
Explain why a topic matters before asking about unfamiliar concepts. Keep each
round focused on the subject the user is currently clarifying.

- Group closely related questions naturally.
- Follow a vague answer with a focused question about the same topic.
- Do not jump to optional workflow preferences while the goal is unclear.
- Do not impose a numeric question limit. Use the smallest coherent round that
  moves the Brief forward.
- If the user gives a detailed answer, infer more and ask less.
- If the user says “I don't know” or “use sensible defaults,” explain the
  defaults plainly and include them in the confirmation rather than continuing
  to interrogate the user.
- Do not optimize optional fields the user did not ask about.

Prefer language at the user's level. Translate Harness terms before using them:

- `cadence` means how cautiously or quickly changes should be delivered.
- `operation_preferences` describe which Git or release actions may be
  suggested or performed after separate in-session authorization.
- `secrets_handling` describes how credentials and sensitive values are stored
  or handled (for example, in an environment file, vault, or keyring) while
  keeping them out of source code, logs, and messages.

## Resolve conflicts explicitly

Never silently choose between user input and contradictory repository evidence.
Handle one conflict at a time, separately from missing-field questions. State
both observations and ask one precise resolution question:

```text
[Field] conflict:
  - The repository indicates: <evidence and path>
  - You said: <user statement>
Which is correct?
  1. Use repository evidence
  2. Use user input
  3. Tell me more
  4. Skip this for now
```

Record the chosen resolution in `conflicts_resolved`. Normalize a choice of
repository evidence, user input, or a third value established through
clarification as `repo`, `user`, or `custom`, respectively, and always include
a non-null `resolved_value`. "Tell me more" starts clarification; it is not
itself a resolution. Normalize a permitted skip as `resolution: "deferred"`
with an explicit `resolved_value: null`.

Execution-critical conflicts cannot be deferred: `goal`, `success_criteria`,
`detected_type` when it identifies the primary project type in the stack, and
`initial_project_state.is_git_repo`. Guided mode remains blocked and performs
no execution until these conflicts are resolved. Quick mode aborts instead of
guessing. Legacy mode may fall back to repository evidence only with an
explicit warning. For other required fields, a deferred conflict still leaves
the Brief incomplete and prevents guided execution.

## Build and confirm the Brief

As answers arrive, preserve confirmed fields and revise only the fields the user
changes. When required fields are complete, present a compact, readable Brief
with source annotations. Explain any important default or unresolved optional
item in plain language.

The confirmation choices are:

- **Approve** — pass the exact confirmed Brief to the executor.
- **Edit** — discuss only the requested changes, preserve other confirmed
  values, and present the revised Brief again.
- **Cancel** — stop with zero target-project writes.

The user confirms the Brief, not the Agent's internal feature breakdown or
implementation plan. In guided mode, target-project writes remain forbidden
until approval. Keep pre-confirmation Brief state in conversation context only.

Quick mode is different: it asks no questions and has no confirmation gate. It
may execute only when the required Brief can be synthesized safely, and it must
warn afterward that the generated Brief was not confirmed. Legacy mode may use
placeholders for compatibility. Resume and update modes require an exact
no-write preview and approval before applying template changes.

## Preserve authority boundaries

The Brief is advisory. Current-session instructions and host security policy
always take precedence. Explicit in-session authorization is still required for
push, merge, tag, release, local skill installation or update, package
installation, external network access or mutation, and destructive actions.

If the user stops or denies an action, stop immediately. Do not argue from an
older Brief preference. Record the denial when the active workflow provides an
evidence sink.

## Resume conversation only for meaningful events

After initialization, do not keep prompting merely to maintain activity.
Resume the dialog only for new authorization, a conflict, a scope change, a
real blocker, or completion of a major phase. Post-init reporting follows
`post-init-explanation.md` when that reference is available.
