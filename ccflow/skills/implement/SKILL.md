---
name: implement
description: Full implementation pipeline — plan, test, implement, review, PR
argument-hint: <ticket-id | task description> [additional context]
user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task, AskUserQuestion, mcp__context7, mcp__pencil__batch_get, mcp__pencil__get_variables, mcp__pencil__get_screenshot, mcp__pencil__snapshot_layout, mcp__pencil__get_editor_state
---

Read the `subagent-safety` reference skill before delegating work to subagents.

## Context

**Config check**: Before anything else, verify `.claude/config.json` exists by reading it. If the file does not exist, **stop immediately** and tell the user:
"ccflow is not configured for this project. Run `/ccflow:configure` first to set up."

Read `.claude/config.json`.
Read the `claudeMdLocation` field from `.claude/config.json` to determine where `CLAUDE.md` is located (defaults to `.claude/CLAUDE.md` if not set).
Read `.claude/rules/lessons-learned.md` before any implementation.
Read relevant `.claude/rules/*.md` files based on the work involved.

### Monorepo Context Loading

If `isMonorepo` is `true` in `.claude/config.json`:

1. **Determine affected project(s)**: From the ticket description and file paths, match against the `projects` array in config to identify which project(s) the ticket affects.
2. **Read per-project CLAUDE.md**: For each affected project, read `<project-path>/CLAUDE.md` for project-specific stack details and conventions.
3. **Read per-project lessons**: For each affected project, read `.claude/rules/lessons-learned-<slug>.md` for project-specific lessons.
4. **Use project-specific commands**: When delegating to subagents, use the project's `buildCommand` and `testCommand` from config instead of inferring them globally.
5. **Pass project context to subagents**: When delegating to planner/implementer, include the per-project CLAUDE.md content and per-project lessons alongside the global context.

### Design Context Loading

If `pencil.enabled` is `true` in `.claude/config.json`:

1. **Determine design path**: Read `pencil.designPath` from config. If the project is a monorepo with `pencil.shared: false`, use the per-project `designPath` from the affected project's entry in the `projects` array.
2. **Load DESIGN.md**: If `<designPath>/DESIGN.md` exists, read it and store as `designSpec`. This contains screen-to-route mappings, component-to-code mappings, design tokens, and naming conventions.
3. **Note .pen file path**: Record the `.pen` file path from the DESIGN.md header for planner reference. Do not read the `.pen` file yet — subagents cannot use Pencil MCP tools, so `.pen` content must be pre-read by the main agent if needed.
4. **Parse design structure from DESIGN.md** (if loaded):
   - Extract screen node IDs from the Screens table (these are Pencil node identifiers)
   - Extract component node IDs and their framework component mappings from the Components table
   - Extract design token references (CSS custom properties) from the Design Tokens section
   - Store these parsed values as `designScreenIds`, `designComponentMap`, and `designTokens` for use in Phase 1 (planner) and Phase 4 (implementer)
5. **Pencil MCP availability probe**: Before any Pencil MCP calls later in the pipeline, attempt a lightweight probe:
   ```
   Call `get_editor_state()` — if it succeeds, Pencil MCP is available for live reads.
   If it fails or times out, set `pencilMcpAvailable = false`.
   ```
   If the probe fails, inform the user: "Pencil MCP unavailable — proceeding with DESIGN.md text content only. Open Pencil and retry if live design reads are needed."
   This probe runs once during context loading. Do not auto-launch Pencil.

If `pencil.enabled` is not `true` or `pencil` is absent, skip this section.

**Shell rules**: Read the `shell-rules` skill before running any `gh` commands (covers heredoc temp-file pattern).

**Parse `$ARGUMENTS` — Mode Detection:**

Extract the first whitespace-delimited token from `$ARGUMENTS` and determine the mode:

- **If the first token matches `^\d+$` or `^#\d+$`** → **ticket mode**
  - Strip any `#` prefix to get the numeric ticket ID.
  - Everything after the first token is optional **user context** (additional instructions or focus areas).
  - Examples: `#1 focus on API` → ID `1`, context `focus on API`; `7` → ID `7`, no context.

- **If the first token ends in `.md` and resolves to a file in `.claude/plans/`** → **plan file mode**
  - Read the plan file. Parse the YAML front matter (between `---` delimiters) to extract metadata: `version`, `mode`, `ticketId`, `ticketTitle`, `slug`, `isChild`, `isLastChild`, `parentId`, `planCommitSha`, `createdAt`, `status`.
  - Set `hasPlanFile = true`.
  - Inherit the original mode (`ticket` or `ticketless`) from the front matter's `mode` field.
  - If `mode` is `ticket`, set the ticket ID and slug from front matter. If `mode` is `ticketless`, set the slug from front matter.
  - The rest of `$ARGUMENTS` after the file path is ignored.

- **Otherwise** → **ticketless mode**
  - The entire `$ARGUMENTS` string is the **task description**.
  - Generate a **slug** from the description: take the first 4–5 meaningful words, lowercase, hyphenated.
    For example: `add dark mode support for the dashboard` → slug `add-dark-mode-support`.
  - There is no ticket ID and no separate user context — the task description is the primary input.

The determined mode (ticket or ticketless) governs conditional behavior throughout the rest of this skill.

**Plan file auto-detection** (ticket mode only): If the first token is a ticket ID (ticket mode) and a file matching `.claude/plans/<id>-*.md` exists, present the user with a choice using `AskUserQuestion`:
- **"Use existing plan"** — switch to plan file mode, set `hasPlanFile = true`, read the plan file
- **"Re-plan from scratch"** — ignore the plan file, proceed with normal ticket mode

**If ticket mode:** Fetch the ticket:
Extract owner/repo from `git remote get-url origin` (e.g. `git@github.com:owner/repo.git` → `owner/repo`), then run:
```bash
gh issue view <number> --repo <owner>/<repo> --json number,title,body,labels,state,assignees,milestone,comments
```

**If ticketless mode:** Skip ticket fetching. The task description from `$ARGUMENTS` is the primary input.

## Parent-Child Detection

**If ticketless mode:** Skip this section entirely.

**If ticket mode:** After fetching the ticket, detect whether this is a child ticket created by `/ccflow:refine` splitting:

1. **Identify parent**: Parse the ticket body for `Related to #<number>`. If found, this is a child ticket — extract the parent ID.

2. **Fetch the parent ticket**: Use the same fetch command as above (`gh issue view`). Check the parent's `state` — if already closed, set `isChild = true`, `isLastChild = false`, `parentId = <id>` and skip to Attachments (don't try to close an already-closed parent).

3. **Find siblings**: Look for a `### Child Tickets` section in the parent's body. Extract sibling issue numbers from lines matching `- [ ] #<number>` or `- [x] #<number>`.

   **Fallback** if no `### Child Tickets` section exists: search for siblings via:
   ```bash
   gh issue list --repo <owner>/<repo> --search "\"Related to #<parentId>\"" --state all --json number
   ```

4. **Determine if last child**: Check how many siblings are still open (excluding the current ticket):
   ```bash
   gh issue list --repo <owner>/<repo> --search "\"Related to #<parentId>\"" --state open --json number
   ```
   If the only open sibling is the current ticket → `isLastChild = true`

5. **Store state** for later use in commit, PR body, and labeling:
   - `isChild` — whether this ticket has a parent
   - `isLastChild` — whether this is the last open child (triggers parent auto-close)
   - `parentId` — the parent ticket number/ID

**Edge cases:**
- Parent already closed → `isLastChild = false` (skip auto-close)
- No `### Child Tickets` section on parent → use search fallback
- Some siblings manually closed → they don't count as open, don't block last-child detection

## Attachments

**If ticketless mode:** Skip the Attachments section entirely and proceed to Pre-flight Check.

**If ticket mode:** Read the `attachments` reference skill and follow its 4-step procedure to discover, present, download, and load ticket attachments. If no attachments are found or the user selects none, proceed to Pre-flight Check.

Store each attachment's file path for passing to subagents (subagents share the filesystem and can read attachments directly via `Read`).

## Pre-flight Check

### Settings Verification

**Before fetching the ticket (or before proceeding in ticketless mode)**, read `.claude/settings.json` and `.claude/config.json` and verify the required permissions are present:

1. Check `permissions.allow` in `.claude/settings.json` contains **at minimum**:
   - `Write(*)`
   - `Edit(*)`
2. Read `.claude/config.json` and check feature-specific permissions in `permissions.allow`:
   - If `mcpServers` exists in config, for each server where value is `true`:
     verify its tool permissions exist in `permissions.allow`
     (Context7: `mcp__plugin_ccflow_context7__resolve-library-id` and `mcp__plugin_ccflow_context7__query-docs`;
      project MCPs: `mcp__<name>__*`)
   - Legacy support: if `context7Enabled: true` exists (no `mcpServers` field), treat as `mcpServers.context7: true`
   - Verify `Bash(gh *)` exists
3. Verify CLI authentication:
   - Run `gh auth status` and verify it returns authenticated

If any permissions are missing, **offer to auto-fix** by appending the missing entries:

> "Missing permissions in `.claude/settings.json`: [list missing items]. This will cause permission dialogs during the pipeline.
> I can auto-fix this by appending the missing entries to `.claude/settings.json`. Want me to fix it?"

If the user approves the auto-fix:
1. Read `.claude/settings.json`
2. Determine the **full set** of missing permissions to append
3. Filter out any entries already present in `permissions.allow`
4. Append only the missing entries to the `permissions.allow` array
5. Write the updated `.claude/settings.json` back
6. Confirm: "Fixed! Added [N] missing permissions. Continuing..."

If the user declines the auto-fix:
> "OK, proceeding without fixing. You may see permission dialogs during the pipeline. Want to continue anyway?"

If the user says no → stop. If yes → proceed.

### Ticket Readiness

**If ticketless mode:** Skip the Ticket Readiness check entirely and proceed to the Pipeline.

**If ticket mode:** After fetching the ticket, inspect its labels/tags before starting the pipeline:

Check the issue's `labels` array.

If the ticket does **not** have a "Refined" label/tag, display a warning:
> "This ticket hasn't been refined yet. Consider running `/ccflow:refine <ticket-id>` first for better results. Do you want to proceed anyway?"

If the user says no → stop. If yes → proceed with the pipeline.

#### Design Check (soft)

If the ticket is classified as frontend — its title, description, or acceptance criteria mention UI components, pages, views, layouts, forms, modals, visual design, styling, CSS, animations, themes, or frontend frameworks (React, Angular, Vue, Svelte, etc.) — and does **not** have a "Designed" label/tag **and** `designSpec` was not loaded (no DESIGN.md found), display a suggestion:
> "This frontend ticket hasn't been designed yet. Consider running `/ccflow:design <ticket-id>` first for a visual reference. Do you want to proceed anyway?"

If the ticket lacks the "Designed" label but a `DESIGN.md` exists (loaded as `designSpec`), skip the suggestion — the design spec is sufficient context.

If the user says no → stop. If yes → proceed with the pipeline. This is a soft-check — it never blocks implementation.

#### Visual Check Reminder

If the ticket has a `ui:visual-check` or `Browser` label, display a reminder:
> "This ticket has the `ui:visual-check` label. Ensure `playwright-cli` is available for visual verification (`playwright-cli screenshot`, `playwright-cli snapshot`)."

This is informational only — it does not block the pipeline.

## Label "Working"

**If ticketless mode:** Skip this section.

**If ticket mode:** Before starting the pipeline, add the "Working" label to signal work in progress:
```bash
gh issue edit <number> --repo <owner>/<repo> --add-label "Working"
```

## Pipeline

This pipeline has 9 phases. Execute them in order. Between major phases, report progress to the user. **Read each phase file only when you reach that phase** — do not read all files upfront.

| Phase | Title | Instructions |
|-------|-------|--------------|
| 1 | Plan | See **Phase 1** section below |
| 2 | Worktree Setup | See **Phase 2** section below |
| 3 | Test First (Red) | See **Phase 3** section below |
| 4 | Implement (Green) | See **Phase 4** section below |
| 5 | Refactor | See **Phase 5** section below |
| 6 + 7 | Security + Code + Silent-Failure Review | See **Phase 6 & 7** section below |
| 8 | Capture Lessons & Update Docs | See **Phase 8** section below |
| 9 | Create PR & Label Ticket | See **Phase 9** section below |

### Phase 1: Plan

**If `hasPlanFile` is true — skip Phase 1:**

1. The plan file was already read and parsed during mode detection. All plan content (implementation plan, architectural context, Q&A, ticket details) is available from the file.
2. **Staleness check**: Compare `planCommitSha` from front matter to `git rev-parse HEAD`. If they differ, warn the user:
   > "The codebase has changed since this plan was created (`planCommitSha` vs current HEAD). The plan may be stale. Continue anyway?"
   Use `AskUserQuestion` with options: "Continue with existing plan", "Re-plan from scratch". If "Re-plan", delete the plan file and proceed with normal Phase 1.
3. **Ticket state check** (ticket mode only): Re-fetch the ticket and compare its state/body to what's stored in the plan file's `## Ticket Details` section. If the ticket was modified since plan creation, warn the user:
   > "The ticket has been modified since this plan was created. Review the changes and confirm."
4. Proceed directly to Phase 2 with all context sourced from the plan file.

**If `hasPlanFile` is false — run Phase 1 normally:**

Analyze the codebase, ask clarifying questions, produce a plan, and get explicit user approval.

**CRITICAL — TWO MANDATORY STOPS IN THIS PHASE:**
1. **After Step 1A**: If the planner has questions → STOP and ask the user (Step 1B). Your turn MUST end with `AskUserQuestion`.
2. **After Step 1C or 1A** (when no questions): Present the plan → STOP and get approval (Step 1D). Your turn MUST end with `AskUserQuestion`.

You MUST NOT proceed to Phase 2 in the same turn as either of these stops. Phase 2 can only begin in a NEW turn after the user selects "Approve".

**COMMON FAILURE MODE**: The model presents the plan's Risks section, calls
AskUserQuestion, then immediately continues to Phase 2 in the same response.
This is WRONG. Your response must END after AskUserQuestion — the user's reply
starts a new turn.

**Prerequisites**: Ticket fetched (ticket mode) or task description parsed (ticketless mode), and pre-flight check passed.

**Ownership**: The planner subagent handles analysis only. The main agent handles all user interaction (questions and approval) via `AskUserQuestion`.

#### Step 1A: Initial Analysis (subagent — planner)

**If ticket mode:** Delegate to the **planner** agent with:
- Full ticket details (description, acceptance criteria, technical notes)
- Relevant lessons from `.claude/rules/lessons-learned.md`
- Relevant rules from `.claude/rules/` files
- **User context** from the arguments (if provided) — present this as additional instructions that should steer the plan. For example: "The user provided this additional context: *focus on the API layer only*"
- **Design spec** (if `designSpec` was loaded): Include the full DESIGN.md content. Tell the planner: "A design spec is available. Include a **Design Mapping** section in the plan output that maps design components (from the Components table) to framework components that will be created or modified. Reference design tokens (CSS custom properties) where applicable."
- **Design reference**: If the ticket body references a `.pen` file path (created by `/ccflow:design`), mention it to the planner so it knows a visual design exists. The planner should note this in its plan so the implementer can reference it during build.
- **Attachments** — pass the file paths so the planner can read them directly (e.g., `/tmp/claude/attachments/mockup.png`). For UI mockups/wireframes, tell the planner: "Read the attached files and ensure the implementation plan matches the visual design."

**If ticketless mode:** Delegate to the **planner** agent with:
- The **task description** from `$ARGUMENTS` as the primary specification
- Relevant lessons from `.claude/rules/lessons-learned.md`
- Relevant rules from `.claude/rules/` files
- **Design spec** (if `designSpec` was loaded): Include the full DESIGN.md content. Tell the planner: "A design spec is available. Include a **Design Mapping** section in the plan output that maps design components to framework components. Reference design tokens where applicable."
- Note that there are no formal acceptance criteria — the planner should derive scope from the description and clarify ambiguities via questions

The planner reads and analyzes the codebase (existing patterns, affected files, dependencies) and returns:
- **Clarifying questions** (if any) — as a numbered list under `## Clarifying Questions`
- **Draft implementation plan** — using the planner's standard output format

**Reference question categories** the planner should evaluate (skip any already answered by the ticket):
1. **Scope boundaries** — What's in scope vs. explicitly out of scope?
2. **Edge cases** — How should the system behave for empty inputs, null values, concurrent access, or boundary conditions?
3. **Error handling** — Toast notification, inline error, redirect, retry, or silent log? What does the user see on failure?
4. **Performance** — Are there latency targets, payload size limits, or pagination requirements?
5. **Backward compatibility** — Can existing APIs/schemas/contracts change, or must changes be additive only?
6. **Integration points** — What external services, shared components, or cross-team boundaries are involved?

Maximum 6 questions — only ask questions whose answers would change the plan.

#### Step 1A-POST: Route Planner Output

After the planner returns, parse its output:
- Check for `## Clarifying Questions` section
- If questions exist AND the section does not say "None" → go to Step 1B (MANDATORY)
- If no questions or "None" → go to Step 1D (MANDATORY — plan approval is ALWAYS required)
- NEVER skip to Phase 2 directly. Every plan needs explicit user approval.

#### Step 1B: Ask Clarifying Questions (main agent)

> **MANDATORY STOP** — This step requires user interaction. Your turn MUST end with `AskUserQuestion`.

If the planner returned clarifying questions:
- Extract each question from the `## Clarifying Questions` section
- Present ALL questions to the user using `AskUserQuestion`
- Do NOT summarize, paraphrase, or skip any question — use the planner's wording
- Do NOT proceed to Step 1C or 1D until the user has answered
- **Your response MUST end here** — the next step happens in a new turn after the user answers

If the planner returned no questions, skip to Step 1D.

#### Step 1C: Revise Plan (subagent — planner, only if Step 1B ran)

Re-invoke the **planner** agent with:
- The original ticket details (ticket mode) or task description (ticketless mode)
- All Q&A pairs from Step 1B
- Any new requirements the user added during Q&A

The planner produces a revised plan (and may include new clarifying questions).

If the revised plan contains new clarifying questions, **loop back to Step 1B**.

#### Step 1D: Plan Approval Gate (main agent)

> **MANDATORY STOP** — This step requires user interaction. Your turn MUST end with `AskUserQuestion`.

Present the **full plan text** to the user as markdown output, then call `AskUserQuestion`. This is a gate — implementation CANNOT begin without explicit approval.

**Output template — follow this structure exactly:**

```
## Implementation Plan

<paste the planner's full plan here — files to modify, implementation steps, testing approach>

### Assumptions
<list each assumption for the user to verify>

### Open Questions
<list anything unresolved, or "None">

### Risks
<list risks for the user to accept>

If the task appears too large for a single PR, consider running `/refine` to split it first.

[Then call AskUserQuestion with Approve / Request Changes options]
```

**WRONG — do not do this:**
```
[present plan]
[call AskUserQuestion]
Now I'll proceed to Phase 2 and create the worktree...
git worktree add .worktrees/...
```

**RIGHT — do this:**
```
[present plan]
[call AskUserQuestion]
← your response ENDS here. Nothing else. No Phase 2. No worktree. No "I'll now proceed."
```

**Explicit prohibitions after calling AskUserQuestion in this step:**
- Do NOT begin Phase 2
- Do NOT create worktrees
- Do NOT say "I'll now proceed..." or "Let me start implementing..."
- Do NOT run any git or bash commands
- Do NOT call any tool other than AskUserQuestion

Use `AskUserQuestion` with options:
- **Approve** — proceed to Phase 2
- **Request Changes** — user wants modifications

If "Request Changes":
1. Ask the user what needs changing (via `AskUserQuestion`)
2. Loop back to **Step 1C** with the change request
3. Re-present the revised plan (back to Step 1D)

**Only proceed to Phase 2 after the user selects "Approve".**

If the task appears too large to implement well in a single PR, recommend the user go back to `/refine` to split it into separate independent tickets (ticket mode) or narrow the scope of the description (ticketless mode) rather than attempting inline decomposition.

#### Step 1E: Persist Plan (after approval)

After the user approves the plan in Step 1D, persist it to disk before proceeding:

1. Create the plans directory: `mkdir -p .claude/plans/`
2. Compose the plan file with YAML front matter and markdown body:

```markdown
---
version: 1
mode: ticket | ticketless
ticketId: 42
ticketTitle: "Add dark mode support"
slug: add-dark-mode
isChild: false
isLastChild: false
parentId: null
createdAt: 2026-03-04T10:30:00Z
status: approved
planCommitSha: abc123def
---

## Ticket Details
<verbatim ticket body or task description>

## User Context
<additional user context from arguments, or "None">

## Q&A from Planning
<numbered Q&A pairs from Steps 1B/1C, or "No questions asked">

## Implementation Plan
<full planner output: summary, assumptions, alternatives, files to modify/create, implementation order, risks>

## Architectural Context
<patterns, conventions, code structures discovered during planning exploration>

## Design Context
<DESIGN.md content or .pen file path if applicable, or "N/A">

## Attachment Summaries
<image/document summaries if applicable, or "None">
```

3. Write the file:
   - **Ticket mode**: `.claude/plans/<ticket-id>-<slug>.md`
   - **Ticketless mode**: `.claude/plans/<slug>.md`
4. Record `planCommitSha` as the output of `git rev-parse HEAD`
5. For ticketless mode, omit `ticketId`, `ticketTitle`, `isChild`, `isLastChild`, and `parentId` from the front matter.
6. Inform the user: "Plan saved to `.claude/plans/<filename>`. You can continue now or resume in a new session."
7. Ask the user using `AskUserQuestion`:
   - **"Continue implementation now"** — proceed to Phase 2 (current flow preserved)
   - **"Stop here (implement later in a fresh session)"** — end the skill. The plan file remains for later use. Tell the user: "Plan saved. Start a new session and run `/ccflow:implement .claude/plans/<filename>` to resume, or the SessionStart hook will remind you."
#### Optional: Deep Codebase Exploration

If `.claude/config.json` contains `"deepExploration": true`, run an exploration step **before** Step 1A:

1. Launch 2 Explore-type subagents in parallel:
   - **Explorer 1**: Focus on the feature area — find related components, services, and patterns in the parts of the codebase most relevant to the ticket/task
   - **Explorer 2**: Focus on cross-cutting concerns — find shared utilities, middleware, configuration, and integration points that the feature will interact with

2. Feed their findings into the planner prompt alongside the ticket details. This produces deeper understanding for large codebases.

If `deepExploration` is not set or is `false`, skip directly to Step 1A (the default behavior).

### Phase 2: Worktree Setup

**GATE CHECK — Verify before proceeding:**
1. You presented the full plan text in Step 1D ✓
2. The user explicitly selected "Approve" in their response ✓
3. This is a NEW turn — not the same turn where you presented the plan ✓

If ANY of these are false, STOP. Go back to Step 1D.

After plan approval, create a git worktree for this feature.

First, verify at least one commit exists (required by `git worktree add`):
```bash
git rev-parse HEAD 2>/dev/null
```
If this fails (no commits exist), create an initial commit:
```bash
git add -A && git commit -m "chore: initial commit" --allow-empty
```
Use `--allow-empty` as a fallback in case there are no files to stage.

Then create the worktree:

- **If ticket mode:**
  ```bash
  git worktree add .worktrees/<ticket-id>-<description> -b feature/<ticket-id>-<description>
  ```
- **If ticketless mode:**
  ```bash
  git worktree add .worktrees/<auto-slug> -b feature/<auto-slug>
  ```

All subsequent phases execute inside the worktree.
The worktree directory is automatically within the sandbox's write scope since it's under CWD.

<details>
<summary>### Phase 3: Test First (Red)</summary>

Delegate to the **implementer** agent.
Tests should fail (red phase).

**Prerequisites**: Plan approved (or loaded from plan file), worktree created, working inside the worktree directory.

#### Process

1. Review the approved plan's implementation order
2. Delegate to the **implementer** agent with instructions to write tests first. **Include the planner's file analysis** to reduce redundant reads — pass along:
   - The **Files to Modify** and **Files to Create** lists from the plan (with the planner's notes on what changes in each)
   - Key architectural context the planner discovered (patterns, conventions, relevant existing code)
   - **If `hasPlanFile` is true**: Source all of the above from the plan file's `## Implementation Plan` and `## Architectural Context` sections instead of conversation memory
   - If attachments included UI mockups, wireframes, or screenshots, pass the file paths (e.g., `/tmp/claude/attachments/mockup.png`) so the implementer can read them directly and write tests that reflect the expected UI structure and behavior
   - If `designSpec` was loaded, include the **Components table** and **Design Tokens** sections so tests can verify correct component structure and token usage
   - Worktree path: `<worktree-path>`. First Bash command: `cd <worktree-path>`. CWD persists — do not cd again.
3. For each item in the plan, write tests that cover:
   - The acceptance criteria from the ticket
   - Edge cases identified during planning
   - Error scenarios and boundary conditions
4. Run the test suite — tests **should fail** (red phase)
5. Report which tests exist and their failure reasons

#### Test Priority

**Frontend stacks** (Angular, React, Vue, Next.js, Svelte):
- Read the `testing` reference skill's **UI Component Classification** section
- For each component/page in the plan, use the classification to select test types
- Write E2E tests for critical journeys first, then integration/component tests, then unit tests
- Note visual-sensitive components for post-implementation verification in Phase 4

**Backend stacks:**
- **Integration tests first**: Real flows that exercise the actual behavior end-to-end
- **Unit tests only for**: Complex domain logic (calculations, state machines, validation rules)

#### Test Quality Rules

Assert **behavior and business rules**:
- Status codes, response shapes, business state changes
- NOT call counts, NOT hardcoded magic values, NOT values copied from implementation

Tests should be:
- Readable as requirements documentation
- Independent of each other (no shared mutable state)
- Deterministic (no timing dependencies, no random values without seeds)

#### Output

List of tests written with their current status (all should be failing).
If any test passes before implementation, investigate — it may indicate the test isn't testing new behavior.

#### Error Recovery

If tests can't be written (missing test infrastructure, unclear requirements):
1. Identify exactly what's blocking
2. If it's a missing dependency or configuration, fix it
3. If requirements are unclear, escalate to the user — do not guess

</details>

<details>
<summary>### Phase 4: Implement (Green)</summary>

Delegate to the **implementer** agent.
Tests should pass (green phase).

**Error recovery**: If build or tests fail, the implementer retries up to 3 times.
If still failing after 3 attempts, stop and ask the user.

**Prerequisites**: Tests written and failing (red phase complete).

#### Design Structure Pre-Reading (if pencil.enabled and pencilMcpAvailable)

Before delegating to the implementer, the **main agent** pre-reads design structure from the `.pen` file so the implementer subagent receives it as text context (subagents cannot use Pencil MCP tools).

1. **Identify relevant screens**: From the ticket description and implementation plan, determine which screens (by node ID from `designScreenIds`) are affected by this ticket.
2. **Read design structure**: For each relevant screen, call:
   ```
   batch_get(nodeIds: [<screen-node-id>], readDepth: 3)
   ```
   This returns the full component hierarchy for that screen. Store the output as `designStructure`.
3. **Read design tokens**: Call:
   ```
   get_variables()
   ```
   This returns all design tokens (spacing, colors, typography) with current values. Store as `designTokenValues`.
4. **Capture visual reference**: For each relevant screen, call:
   ```
   get_screenshot(nodeId: <screen-node-id>)
   ```
   Store the screenshot references for the implementer to compare against.

If any Pencil MCP call fails, inform the user which calls failed and what data will be missing. Proceed with DESIGN.md text content only — do not block implementation.

**Pass to implementer**: Include `designStructure`, `designTokenValues`, and screenshot references as text context in the implementer delegation prompt. If any data is missing due to MCP failures, note which pieces are absent so the implementer knows the design context is partial. Tell the implementer: "Use this design structure for component hierarchy. Use design token values for spacing, colors, and typography. Compare your implementation visually against the provided screenshots."

#### Process

1. Delegate to the **implementer** agent with instructions to make failing tests pass. **Carry forward the same planner context** provided in Phase 3 (file lists, architectural notes) so the implementer doesn't re-read files it already analyzed. **If `hasPlanFile` is true**: Source context from the plan file's `## Implementation Plan` and `## Architectural Context` sections.
   - If attachments included UI mockups, wireframes, or screenshots, pass the file paths (e.g., `/tmp/claude/attachments/mockup.png`) so the implementer can read them directly and match the expected visual design
   - If `designSpec` was loaded, include the full DESIGN.md content — component hierarchy, UI library mappings, CSS custom property references from design tokens. Tell the implementer: "Use the DESIGN.md component mappings and design tokens for implementation. Map design components to framework components as specified in the Components table. Use CSS custom properties from the Design Tokens section."
   - If `lspServers` in `.claude/config.json` has any enabled servers, tell the implementer: "LSP diagnostics are active — fix type errors and unused code after each edit"
   - Worktree path: `<worktree-path>`. First Bash command: `cd <worktree-path>`. CWD persists — do not cd again.
2. Follow the approved plan's implementation order
3. For each failing test:
   - Write the minimum code to make it pass
   - Run the test to confirm it passes
   - Ensure no previously passing tests have broken
4. Run the full build and test suite after all changes
5. All tests should **pass** (green phase)

#### Visual Verification (frontend stacks, when applicable)

After all functional tests pass, if the plan's Test Strategy includes visual components:
1. **Playwright Test (primary)**: If Playwright is configured (`playwright.config.*` exists), write visual regression tests using `toHaveScreenshot()` — these run in CI and catch regressions automatically
2. **Playwright CLI (interactive checks)**: Use `playwright-cli open <url>`, `playwright-cli screenshot`, `playwright-cli snapshot` for dev verification — layout inspection, CSS debugging, responsive behavior. Playwright CLI verifications are ephemeral and do NOT replace Playwright Test.
3. If neither available: note in PR description that visual verification was not performed

See the `testing` skill's "Browser Testing Tools" section for the full decision framework.

#### Design Comparison (if pencil.enabled and pencilMcpAvailable)

After functional tests pass and standard visual verification is complete:

1. **Screenshot comparison**: Use the screenshot references captured during Design Structure Pre-Reading. If not available (pre-reading was skipped or failed), call `get_screenshot(nodeId: <screen-node-id>)` per screen. Compare side-by-side with the Playwright screenshot of the implemented page. Note any significant visual discrepancies.
2. **Layout verification**: Call `snapshot_layout` to check for layout problems:
   ```
   snapshot_layout(parentId: <screen-node-id>, problemsOnly: true)
   ```
   Review the layout rectangles for clipping, overflow, or misalignment issues that might indicate the implementation diverges from the design.
3. If discrepancies are found, list them and delegate fixes to the implementer. Re-run the comparison after fixes. Only proceed to Phase 5 once comparison passes or the user explicitly accepts the remaining gaps.

If Pencil MCP is unavailable (`pencilMcpAvailable = false`), skip this section and note in the PR description that design comparison was not performed.

#### Rules

- Follow the approved plan exactly
- Make failing tests pass with the **simplest correct implementation**
- Follow patterns from `.claude/rules/` files
- Follow lessons from `.claude/rules/lessons-learned.md`
- No premature abstractions — keep it simple
- No dead code, no commented-out code, no TODOs without ticket references

#### Verification

After implementation:
1. Run the full build — must succeed
2. Run the full test suite — all tests must pass
3. Report the results

#### Error Recovery

If build or tests fail:
1. Analyze the failure output carefully — identify the root cause, not just the symptom
2. Fix the root cause
3. Re-run build and tests
4. If still failing after 3 attempts, stop and report to the user with:
   - The exact error output
   - What you tried
   - Your best hypothesis for the root cause

</details>

<details>
<summary>### Phase 5: Refactor</summary>

Delegate to the **implementer** agent.
Run tests after — must still pass.

**Prerequisites**: All tests passing (green phase complete).

#### Process

1. Delegate to the **implementer** agent with refactoring instructions.
   - If `lspServers` in `.claude/config.json` has any enabled servers, tell the implementer: "Use LSP diagnostics to identify unused code during refactoring"
   - Worktree path: `<worktree-path>`. First Bash command: `cd <worktree-path>`. CWD persists — do not cd again.
2. Review all changes made in this implementation for:
   - Dead code or unnecessary abstractions — remove them
   - Duplicated logic — consolidate into shared helpers only if used 3+ times
   - Unclear names — rename for clarity
   - Complex conditionals — simplify (extract guard clauses, reduce nesting)
   - Overly clever code — replace with straightforward alternatives
3. Run the full test suite after refactoring — must still pass
4. If any test fails, revert the last refactoring step and try a different approach

#### Rules

- Refactoring must not change behavior — tests are the safety net
- Keep it as simple as possible — don't introduce new patterns
- Don't refactor code that wasn't touched in this implementation
- Small, incremental changes — don't refactor everything at once

#### Error Recovery

If tests fail after refactoring:
1. Identify which refactoring step broke the test
2. Revert that specific change
3. Try a simpler refactoring or skip that particular cleanup

</details>

<details>
<summary>### Phase 6 & 7: Security Review + Code Review (parallel)</summary>

These phases are independent read-only operations and **MUST run in parallel**.

#### Parallel Execution Pattern

1. **Gather shared context ONCE** before launching reviewers — batch all git operations into a **single Bash call** to minimize round-trips:
   ```bash
   echo "===DIFF===" && git diff && echo "===FILES===" && git diff --name-only && echo "===STAT===" && git diff --stat
   ```
   Parse the output by delimiter to extract: full diff (between `===DIFF===` and `===FILES===`), changed file list (between `===FILES===` and `===STAT===`), and diff summary stats (after `===STAT===`). Also have the original ticket requirements and the approved implementation plan ready from earlier phases — do not re-fetch them. **If `hasPlanFile` is true**: Source ticket requirements from the plan file's `## Ticket Details` section and the implementation plan from `## Implementation Plan`.

2. **Launch ALL THREE reviewers as parallel Task tool calls in a SINGLE message:**
   - Task 1: **security-reviewer** agent — pass it the diff output, new/modified file list
   - Task 2: **code-reviewer** agent — pass it the diff output, ticket requirements, implementation plan
   - Task 3: **silent-failure-hunter** agent — pass it the diff output, new/modified file list

   All agents receive the pre-gathered diff so none need to run `git diff` independently.

3. **Wait for all to complete**, then **process results by priority** — security-critical findings first:
   - If the **security reviewer** reports any **CRITICAL** findings, fix those immediately before processing other review results. Critical security issues (auth bypass, injection, data exposure) take precedence over code quality or style concerns.
   - If no CRITICAL security findings, process all three reviewer outputs together (see phase details below).

#### Phase 6 — Security Review

Delegate to the **security-reviewer** agent.
If Critical or High findings: fix them (delegate back to implementer), re-run tests, re-review.
If fix is unclear, stop and ask the user.

**Prerequisites**: Tests pass, refactoring complete, shared diff context gathered.

##### Process

1. Receive the pre-gathered diff output and new/modified file list (do NOT run `git diff` again)
2. Delegate to the **security-reviewer** agent with the context above
3. The agent traces data flow from input to storage/output and checks for vulnerabilities
4. Process findings by severity (see Actions below)

##### Expected Output

The agent returns findings with severity levels (Critical/High/Medium/Low), plus a **Passed Checks** checklist.

##### Actions

- **Critical or High**: Fix immediately. Delegate fixes to the **implementer** agent. Re-run tests. Re-run security review on the fixes.
- **Medium or Low**: Note in the PR description as known items.
- **If fix is unclear**: Stop and ask the user for guidance.

##### Error Recovery

If the security reviewer identifies an issue but the fix is unclear:
1. Present the finding to the user with full context
2. Ask for guidance on the preferred fix approach
3. Implement the fix and re-run the security review

#### Phase 7 — Code Review

Delegate to the **code-reviewer** agent.
Fix "Must Fix" issues (confidence >= 90). Note anything needing human decision.

**Prerequisites**: Tests pass, refactoring complete, shared diff context gathered.

##### Process

1. Receive the pre-gathered diff output, ticket requirements, and approved implementation plan (do NOT run `git diff` again)
2. Delegate to the **code-reviewer** agent with all context above.
   - If `lspServers` in `.claude/config.json` has any enabled servers, tell the code-reviewer: "LSP servers are active — unaddressed warnings are high-confidence findings"
3. The agent reviews using confidence scoring (0–100) and only reports issues >= 50 confidence
4. Process the results by confidence tier (see Actions below)

##### Expected Output

The agent returns issues with confidence scores, categorized as:
- **Must Fix** (confidence >= 90) — verified bugs, missing error handling, convention violations
- **Should Fix** (confidence 75–89) — likely issues with strong evidence
- **Nitpicks** (confidence 50–74) — possible concerns, style suggestions

Plus a **Passing Checks** checklist and **Verdict** (APPROVE / APPROVE_WITH_SUGGESTIONS / REQUEST_CHANGES).

##### Actions

- **Must Fix** (>= 90): Fix all issues. Re-run tests after fixes.
- **Should Fix** (75–89): Fix if straightforward. Note in PR description if deferred.
- **Nitpicks** (50–74): Ignore unless trivial to address.
- **Needs human decision**: Stop and ask the user.

##### Error Recovery

If the reviewer returns REQUEST_CHANGES:
1. Delegate fixes to the **implementer** agent
2. Re-run tests to verify fixes don't break anything
3. Re-run code review on the fixed code
4. If the same issue persists after 2 fix attempts, escalate to the user

#### Silent Failure Review

Delegate to the **silent-failure-hunter** agent.
This runs in parallel with the security and code reviewers.

##### Process

1. Receive the pre-gathered diff output and new/modified file list
2. The agent scans for silent failure patterns: empty catch blocks, swallowed errors, missing error propagation, silent fallbacks
3. Findings are merged with the code review results

##### Actions

- **Critical** (error swallowed in auth/payment/data-loss paths): Fix immediately
- **Warning** (empty catch, silent fallback in non-critical paths): Fix if straightforward, note in PR description if deferred
- **Info** (intentional suppression with comment): No action needed

</details>

<details>
<summary>### Phase 8: Capture Lessons & Update Docs</summary>

Skip entirely if no self-corrections occurred and no doc updates are warranted.

**Prerequisites**: Code review and security review complete, all fixes applied.

#### Step 8A: Capture Lessons

Delegate to the **lessons-collector** agent.
Skip if no self-corrections occurred during the session.

1. Review the conversation/session for self-corrections:
   - Build errors that required fixes
   - Wrong APIs or patterns used then corrected
   - Test failures with non-obvious causes
   - Incorrect assumptions that led to rework
2. If self-corrections occurred, delegate to the **lessons-collector** agent
3. The agent appends entries to `.claude/rules/lessons-learned.md` in the target project

**Skip Step 8A if no self-corrections occurred during the session.**

##### Quality Criteria for Lessons

Each lesson must be:
- **Specific** — "Used `findOne` instead of `findUnique` in Prisma" not "Made a mistake"
- **Actionable** — includes a clear rule to prevent recurrence
- **Non-duplicate** — check existing entries before adding

##### Error Recovery

If `.claude/rules/lessons-learned.md` doesn't exist, create it with a header.
If it exceeds 100 entries, suggest consolidating related entries into permanent rules in `.claude/rules/<topic>.md`.

#### Step 8B: Update CLAUDE.md (if warranted)

**Update when:**
- A new architectural pattern was established that future work must follow
- A new integration point or external dependency was introduced with specific usage rules
- A convention was discovered that prevents mistakes if documented at project level

**Do NOT update for:**
- Routine features following existing patterns
- Lessons already captured in `lessons-learned.md`
- Implementation details specific to one feature

**Process:**
1. Read `claudeMdLocation` from `.claude/config.json` (default: `.claude/CLAUDE.md`)
2. Read current CLAUDE.md content
3. Append new rules under `## Critical Rules` as bullet points
4. Do not remove or rewrite existing content — only append

#### Step 8C: Update README.md (if warranted)

**Update when:**
- New command, API endpoint, or user-visible feature was added
- Configuration options changed
- Setup/installation steps changed
- New prerequisites or dependencies were introduced

**Do NOT update for:**
- Internal refactoring, bug fixes, test-only changes
- Changes with no user-facing impact

**Process:**
1. Read `README.md` at project root
2. Add documentation matching existing style/structure
3. Keep changes minimal

</details>

<details>
<summary>### Phase 9: Create PR</summary>

Rebase on latest main, then handle commit, push, and PR creation.

**Prerequisites**: Code review complete, all Must Fix items resolved, tests pass. Network access required for `git fetch`.

**If `hasPlanFile` is true**: Source `ticketId`, `slug`, `isChild`, `isLastChild`, and `parentId` from the plan file's front matter for commit messages, branch names, and PR body references.

#### Step 1: Rebase on Latest Main (main-agent-only — requires auth)

Fetch and rebase onto the latest main branch to catch conflicts before creating the PR:

```bash
git fetch origin main
git rebase origin/main
```

**If rebase succeeds**: Re-run the full build and test suite to verify nothing broke.
- If tests **pass** → proceed to Step 2 (Commit).
- If tests **fail** → stop the pipeline and report the failures to the user. The rebase introduced incompatibilities that need manual resolution.

**If rebase fails** (conflicts): Abort the rebase, stop the pipeline, and report to the user:
```bash
git rebase --abort
```
Report the conflicting files and provide manual resolution steps:
1. Run `git rebase origin/main` manually
2. Resolve conflicts in the listed files
3. `git rebase --continue`
4. Re-run build and tests
5. Resume the pipeline from Step 2

#### Step 2: Commit

Stage and commit all changes with conventional commit format:

```bash
git add -A
git commit -m "<type>(<scope>): <description>

<body if needed>

<ticket-ref>"
```

**If ticket mode:** Include a ticket reference in the commit message: `#<id>` or `Fixes #<id>`.

**If `isLastChild` is true**, add a second ticket reference line for the parent:
```
Fixes #<childId>
Fixes #<parentId>
```
This causes the PR to auto-close both the child and parent on merge.
If not last child, just `Fixes #<childId>` (unchanged).

**If ticketless mode:** Use a conventional commit with no ticket reference. Omit the `<ticket-ref>` line.

#### Step 3: Push

Try to push the branch:

- **If ticket mode:**
  ```bash
  git push -u origin feature/<ticket-id>-<description>
  ```
- **If ticketless mode:**
  ```bash
  git push -u origin feature/<auto-slug>
  ```

If the push **fails** (e.g., sandbox network restriction, SSH remote), do the following:
1. Display the exact push command to the user
2. Explain that the sandbox may be blocking the push (SSH remotes don't work with sandbox network filtering — HTTPS remotes are recommended)
3. Ask the user to run the push command manually outside Claude Code
4. **Wait for user confirmation** that the push succeeded before proceeding to PR creation

#### Step 4: Create PR

Create the PR using `gh pr create`.

##### PR body template

Write the body to a temp file first, then read it back. **Do not** put the body inline as a single string or use heredocs (they fail in the sandbox).

**If ticket mode**, include the `## Ticket` section in the PR body:

- **If `isLastChild` is true**: The Ticket section should contain both child and parent references:
  ```
  Fixes #<childId>
  Fixes #<parentId> (parent — all children complete)
  ```
- **If `isChild` but NOT `isLastChild`**: The Ticket section should contain:
  ```
  Fixes #<childId>
  Related to #<parentId> (parent — N siblings still open)
  ```
  (Use `Related to` instead of `Fixes` so the parent is NOT auto-closed.)
- **If not a child ticket**: Use the standard `Fixes #<id>` reference.

```bash
printf '%s' '## Summary
<1-2 sentences describing the change>

## Ticket
<ticket references as described above>

## Changes
- <change 1>
- <change 2>
- <change 3>

## Testing
<how it was tested — what tests were written, what was verified>

## Checklist
- [x] Tests pass
- [x] Security review done
- [ ] Documentation updated

## Notes
<any Medium/Low security findings or Should Fix items, or "None">' > /tmp/claude/pr-body.md
BODY=$(cat /tmp/claude/pr-body.md)
gh pr create --title "<type>(<scope>): <description>" --body "$BODY"
```

**If ticketless mode**, omit the `## Ticket` section from the PR body. The template becomes:

```bash
printf '%s' '## Summary
<1-2 sentences describing the change>

## Changes
- <change 1>
- <change 2>
- <change 3>

## Testing
<how it was tested — what tests were written, what was verified>

## Checklist
- [x] Tests pass
- [x] Security review done
- [ ] Documentation updated

## Notes
<any Medium/Low security findings or Should Fix items, or "None">' > /tmp/claude/pr-body.md
BODY=$(cat /tmp/claude/pr-body.md)
gh pr create --title "<type>(<scope>): <description>" --body "$BODY"
```

#### Step 5: Label Ticket

**If ticketless mode:** Skip Step 5.

**If ticket mode:** After PR creation, replace the "Working" label with "Implemented" on the ticket:
```bash
gh issue edit <number> --repo <owner>/<repo> --add-label "Implemented" --remove-label "Working"
```

**If `isLastChild` is true**, also label the parent ticket as "Implemented":
```bash
gh issue edit <parentId> --repo <owner>/<repo> --add-label "Implemented"
```
(GitHub auto-closes the parent via `Fixes #<parentId>` in the PR body on merge.)

#### Error Recovery

- **Rebase conflicts**: Abort the rebase (`git rebase --abort`), report conflicting files, provide manual resolution steps, stop the pipeline
- **Post-rebase test failure**: Tests passed before rebase but fail after — report failures to the user. The rebase introduced incompatibilities that need manual resolution
- **Push fails**: Display the push command, explain sandbox limitations, ask user to push manually
- **PR creation fails**: Check if the branch exists on remote, verify `gh` auth status, retry once

#### Step 6: Plan File Cleanup

**If `hasPlanFile` is true**: After successful PR creation (Step 4 completes), delete the consumed plan file:

```bash
rm .claude/plans/<plan-filename>.md
```

If the `.claude/plans/` directory is now empty, remove it too:

```bash
rmdir .claude/plans/ 2>/dev/null
```

This prevents stale plan files from accumulating. If the pipeline fails before PR creation, the plan file is preserved so the user can retry.

</details>

