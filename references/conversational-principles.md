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
source that supplied each Brief value, not merely a source that did not
contradict it. Values supplied or unambiguously implied by the user's words
(including a project type implied by their goal) use `source: conversation`;
`source: repo` requires supporting repository observations. Absence of
contradictory markers does not turn a conversation-derived value into a
repository inference. Keep this attribution consistent in `provenance`, the
readable Brief, and the post-init explanation:

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
- If the user says “I don't know” or “use sensible defaults,” explain and apply
  only the documented Project Brief defaults—`cadence: stable`, `deadline:
  null`, `secrets_handling: unspecified`, `external_network: ask`,
  `prohibitions: []`, and the ask/false `operation_preferences` object—and
  include them in the confirmation rather than continuing to interrogate the
  user. Record every field that used one of these defaults exactly once in
  `defaults_applied`, with the identical value and a non-empty rationale. This is not
  permission to invent product or implementation defaults such as a framework,
  database, UI architecture, authentication, or deployment choice. Keep those
  optional choices explicitly deferred unless the user supplies them and the
  Brief schema can represent them losslessly.
- For a defaulted field, the `provenance` entry and its matching
  `defaults_applied` entry must use the exact same JSON pointer. Do not record
  leaf defaults such as `/operation_preferences/commit` while summarizing their
  provenance as `/operation_preferences`. Either represent the whole operation
  preferences object once in both places, or use the same leaf pointers in both.
- Do not optimize optional fields the user did not ask about.
- Documented Brief defaults are not questions. Do not ask permission to use
  them or propose an optimized alternative such as a one-off cadence. Once the
  required information is complete, apply those defaults, present the complete
  Brief, and ask only for approval of the Brief.
- When the host supplies the current date and timezone, resolve an unambiguous
  relative deadline such as “due Friday” to the corresponding exact calendar
  date and show that date without asking the user to confirm it. Ask only when
  the wording genuinely permits multiple plausible calendar dates.
- Product implementation mechanisms outside the Brief schema and executor are
  optional, even when they relate directly to the goal. For example, an
  authentication goal requires observable success criteria, but not a choice
  among sessions, tokens, or API keys before Harness initialization. Likewise,
  database, UI, storage, and deployment choices should be deferred unless the
  user volunteers them or a concrete repository conflict makes one
  execution-critical. After the user supplies sufficient success criteria,
  do not re-ask an unanswered optional implementation question.

Prefer language at the user's level. Translate Harness terms before using them:

- `Harness` means the project files and checks that help coding agents work
  consistently and verify their changes.
- A `Git repository` is a project folder whose change history is tracked by
  Git.
- The `stack` is the main language and tools used to build the project.
- A `test framework` is the tool that runs automated checks of the code.
- `cadence` means how cautiously or quickly changes should be delivered.
- `operation_preferences` describe which Git or release actions may be
  suggested or performed after separate in-session authorization.
- `secrets_handling` describes how credentials and sensitive values are stored
  or handled (for example, in an environment file, vault, or keyring) while
  keeping them out of source code, logs, and messages.
- `external network access` means connecting to services outside the local
  project, and `destructive operations` are actions that can erase or
  irreversibly replace data.

If the user says they do not understand the setup, do not merely place these
technical labels in a Brief. Define each term at first use, or replace it with
plain language. Describe guided init as "setup that asks for confirmation"
before using the `/harness:init` command name.

That novice-language mode lasts for the remainder of guided init, including
the required skill-use announcement, progress/commentary updates, every
repeated Brief, and the post-init explanation. Before sending each response,
scan all user-facing prose—not just questions or final answers—for unexplained
technical nouns. The definitions above are examples, not an exhaustive list.
Prefer descriptions such as "a folder with tracked change history," "the main
language and tools," "the tool that runs automated checks," "a record used for
safe updates," and "the folder containing check results" instead of exposing
`Git repository`, `stack`, `test framework`, `snapshot`, or `run-log directory`
without explanation. Likewise, define `framework` as the toolkit used to build
the app if that optional choice must be mentioned. Internal artifact names that
do not help the user may be omitted.

The required announcement that this skill is being used is part of the user
conversation. In novice-language mode, introduce Harness Companion as "the
setup guide that adds project files and checks for consistent, verifiable
coding work" in that same announcement. Keep progress updates about observable
outcomes; do not expose internal phrases such as "machine-readable shape" or
"trusted setup boundary." When a next step mentions `/harness:init`, call it
the confirmation-based setup command before showing the command name; never
leave the phrase "guided `/harness:init`" unexplained.

## Resolve conflicts explicitly

First identify what each statement describes. A goal or success criterion is
a desired outcome, not by itself a claim that the corresponding capability,
file, or test already exists. Preserve that outcome in the Brief and infer
initial state independently using the field definitions in
`project-brief-input.md`. Raise a conflict only when grounded evidence and an
explicit user statement or requested field value contradict for the same
Brief field; do not manufacture a conflicting value from an outcome alone.

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

Always show all four choices. For an execution-critical field, render the
fourth choice as `Skip this for now (initialization will pause)` rather than
omitting it. Choosing it ends the current setup attempt without execution; it
does not make the unresolved conflict permissible in an executable Brief.

Ask that resolution question exactly once in one user-visible response. If a
progress update is useful while inspecting evidence, limit it to status (for
example, "I am checking the repository markers"); do not include the conflict
question or its choice menu there and then repeat it in the final response.
After asking the question, wait for the user's answer instead of paraphrasing
or asking it again in the same turn.

When several fields conflict, choose one field for the current question. Scope
the evidence, wording, and every menu choice to that field alone. Do not offer
composite alternatives such as "Python with pytest" versus "Node with no test
framework" while both `/stack` and `/test_framework` remain unresolved: ask
about `/stack` first, wait for the answer, and raise `/test_framework` in the
next turn. Do not preview the later conflict as part of the current resolution.

Record the chosen resolution in `conflicts_resolved`. Normalize a choice of
repository evidence, user input, or a third value established through
clarification as `repo`, `user`, or `custom`, respectively, and always include
a non-null `resolved_value`. "Tell me more" starts clarification; it is not
itself a resolution. Normalize a permitted skip as `resolution: "deferred"`
with an explicit `resolved_value: null`.

Execution-critical conflicts cannot be deferred into an executable Brief:
`goal`, `success_criteria`,
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

User-supplied goal and success-criterion strings are frozen as soon as they are
provided, not only after the approval turn. Copy them character for character
into the first complete Brief. Capitalization, punctuation, grammar, and list
boundaries are data: do not title-case, add a period, polish the prose, or split
one criterion into several criteria. If the supplied wording is ambiguous or
cannot satisfy the Brief contract, present any proposed rewrite as an explicit
edit and use it only after the user accepts it.

Before constructing the first executor payload, read
`references/project-brief-input.md` and use that exact contract. Do not guess
legacy aliases such as `project_type`, a nested `constraints` object,
`initial_state`, `defaults_applied[].path`, or array-form `provenance`. Never use
the mutation boundary as a schema probe: one approved Brief must produce one
schema-valid first invocation.

Before presenting the complete Brief for approval, run the contract's
read-only `--validate-brief-only` preflight against the exact compact JSON that
will later be executed. This check must make no target-project writes and does
not replace approval. Keep
`initial_project_state.detection_summary` to one concise repository observation
of at most 200 characters. If preflight rejects an unconfirmed representation,
correct it before presentation; if correction would change meaning, ask the
user instead. Do not wait until the approved mutation call to discover a
schema or length error.

After that preflight succeeds, include the exact one-line compact JSON below
the readable Brief in a fenced `json` block titled **Validated execution record**.
This is the conversation-persistent handoff for stateless Agent
turns, not a second representation to rewrite. If the same Brief is presented
again, copy the record byte-for-byte. On approval, use those exact bytes for
the mutation boundary; do not reconstruct `detection_summary`, provenance,
default rationales, or any other field from the readable summary. If the exact
record is missing from conversation context, preflight and present the Brief
again rather than executing a regenerated payload.

The displayed confirmation and the executor input are one contract. Every
decision shown for approval must have a lossless machine-readable counterpart
in the exact Brief sent to the executor. Never obtain approval for a richer
human Brief and silently discard fields while constructing its JSON form.

Normalize known schema identifiers before displaying the confirmation, and use
the same canonical value in JSON. For example, present the machine values
`stack: node` and `test_framework: jest`; do not display `Node.js` or `Jest`
and then silently change their spelling during serialization. Natural prose
may explain the value separately.

After approval, copy the exact presented goal and success-criterion strings
into the executor JSON. Do not reconstruct them from earlier user messages or
change perspective by adding phrases such as “the user's.” If the exact
approved wording is unavailable, present the Brief again; do not execute.

The confirmation choices are:

- **Approve** — pass the exact confirmed Brief to the executor.
- **Edit** — discuss only the requested changes, preserve other confirmed
  values, and present the revised Brief again.
- **Cancel** — stop with zero target-project writes.

Approval applies to the complete displayed Brief, not to isolated choices.
Statements such as "stable cadence sounds good," "use those defaults," or
"that field is correct" confirm only those values. Preserve them, present the
complete resulting Brief, and keep the executor blocked. Invoke the consent
boundary only when the user explicitly approves the complete Brief or
explicitly directs initialization from that displayed Brief.

Display each success criterion as a separate quoted or code-formatted string.
Before the first target write, compare the executor JSON `goal` and each
`success_criteria` element against the last displayed complete Brief exactly,
character for character. Capitalization, punctuation, and list boundaries are data: do
not title-case, lowercase, punctuate, split, or combine an approved string.
Correct a mismatch before invoking the executor, not after initialization.

The user confirms the Brief, not the Agent's internal feature breakdown or
implementation plan. In guided mode, target-project writes remain forbidden
until approval. Keep pre-confirmation Brief state in conversation context only.

Quick mode is different: it asks no questions and has no confirmation gate. It
may execute only when the required Brief can be synthesized safely, and it must
warn afterward that the generated Brief was not confirmed. Legacy mode may use
placeholders for compatibility. Resume and update modes require an exact
no-write preview and approval before applying template changes.

For a concrete post-init Brief edit such as “rename the goal and preserve
everything else,” load the confirmed on-disk Brief, copy every unchanged field
exactly, and apply the named edit before showing the revised complete Brief.
Check the displayed field against the user's requested new value. Do not echo a
stale pre-edit Brief, return to the initial Approve/Edit/Cancel ceremony, or ask
the user to reconfirm unchanged fields. The next confirmation is only for
applying the exact revised update plan.

For a post-init update, do not turn the executor's plan token into a second
consent ceremony. When the exact intended Brief change and preservation
guarantees were just shown and the user explicitly says to apply that exact
safe update, generate the no-write plan, compare its creates, updates, and
preserved files with what was shown, and apply the returned token in the same
turn if they match. Stop and present the new difference only if the dry run
introduces an unshown file action, conflict, or scope change. Never skip the
dry run or apply without its token.

In a sandbox that forbids temporary Brief files, stream the same compact JSON
payload through the trusted boundary for both invocations: first with
`--update` only, then with `--update --apply --plan-token <token>`. The token
binds the stdin payload hash and target state. Do not use the bare managed
resume shortcut, change the payload, or change transport between dry-run and
apply.

After the dry run, treat the compact JSON as an opaque frozen byte string.
Duplicate the complete dry-run pipeline verbatim and append only `--apply
--plan-token <token>`; do not rebuild, abbreviate, or retype the JSON. Before
launching the apply command, compare the two pipeline prefixes character for
character. In particular, every element of `success_criteria`,
`defaults_applied`, and `conflicts_resolved` must be identical in both calls.

## Preserve authority boundaries

The Brief is advisory. Current-session instructions and host security policy
always take precedence. Explicit in-session authorization is still required for
push, merge, tag, release, handling credentials, secrets, API keys, or tokens,
local skill installation or update, package installation, external network
access or mutation, and destructive actions.

When `external_network` is `ask`, distinguish task intent from authorization.
An instruction to run, use, or call a production or other external-service
command says what the user wants done; it does not by itself authorize crossing
the network boundary. Before the first attempt, explain that the action will
access an external service and ask for a separate explicit yes/no authorization.
Proceed only after the user's reply explicitly authorizes external network
access. Do not create a network-attempt marker, invoke the command, or perform a
probe while waiting for that answer.

If the user stops or denies an action, stop immediately. Do not argue from an
older Brief preference. Record the denial when the active workflow provides an
evidence sink. If the user asks the acknowledgement to name a particular
evidence field or sink, preserve those requested audit terms in the response
instead of substituting a looser synonym. For example, acknowledge that the
`external_network denial` is recorded by the `evaluation transcript` when those
are the requested evidence words. Naming the evidence sink does not authorize a
project-file write.

## Resume conversation only for meaningful events

After initialization, do not keep prompting merely to maintain activity.
Resume the dialog only for new authorization, a conflict, a scope change, a
real blocker, or completion of a major phase. Post-init reporting follows
`post-init-explanation.md` when that reference is available.
