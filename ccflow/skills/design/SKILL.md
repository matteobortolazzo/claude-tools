---
name: design
description: Interactive design reasoning and .pen file creation using Pencil
argument-hint: <ticket-id | design description> [additional context]
user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion, WebFetch, mcp__pencil__get_editor_state, mcp__pencil__get_guidelines, mcp__pencil__batch_get, mcp__pencil__batch_design, mcp__pencil__get_screenshot, mcp__pencil__export_nodes, mcp__pencil__find_empty_space_on_canvas, mcp__pencil__snapshot_layout, mcp__pencil__open_document, mcp__pencil__get_variables, mcp__pencil__set_variables, mcp__pencil__replace_all_matching_properties, mcp__pencil__search_all_unique_properties
---

<!-- Architecture note: ccflow orchestrates Pencil via `pencil interactive` CLI (ccflow-driven model).
     We do NOT use `pencil --agent-config` because:
     1. ccflow needs ticket/worktree/approval workflow integration that agent-config agents lack
     2. agent-config agents have no ccflow context (config, rules, lessons-learned)
     3. For complex designs, we batch via multiple `batch_design` calls within one session
     The Pencil editor is the design engine; Claude Code drives it via CLI subprocess (or MCP as legacy fallback).
     CLI mode (`pencil interactive -a desktop`) avoids loading MCP tool schemas into every conversation,
     saving ~3,000-5,000 tokens per conversation and enabling command batching via heredocs. -->

## Phase 0 — Context Loading

**Config check**: Before anything else, verify `.claude/config.json` exists by reading it. If the file does not exist, **stop immediately** and tell the user:
"ccflow is not configured for this project. Run `/ccflow:configure` first to set up."

Read `.claude/config.json`.

**Pencil gating**: Check `pencil.enabled` in `.claude/config.json`. If `pencil` is absent or `pencil.enabled` is not `true`, **stop immediately** and tell the user:
"Pencil design workflows are not enabled for this project. Run `/ccflow:configure` and enable Pencil when prompted."

Read `pencil.designPath` from the config to determine where design files belong. If the project is a monorepo with `pencil.shared: false`, determine the per-project `designPath` from the affected project's entry in the `projects` array.

## Pencil Communication Mode

Read `pencil.mode` from `.claude/config.json` and store as `$PENCIL_MODE`. Default: `"editor"` if absent.

**Convention**: All Pencil tool calls in this skill follow `$PENCIL_MODE`:

- **`"cli-app"`** (default for new installs): Execute tool calls via `pencil interactive -a desktop` heredoc using the Bash tool. Multiple independent commands can be batched in a single heredoc.

  ```bash
  pencil interactive -a desktop <<'EOF'
  tool_name({ key: value })
  another_tool({ key: value })
  EOF
  ```

  Split into separate heredoc invocations at **decision boundaries** — where you need to read output before choosing the next action.

- **`"editor"`** (legacy MCP fallback): Call the equivalent `mcp__pencil__<tool>` MCP tool directly (e.g., `mcp__pencil__batch_design`). One tool call per invocation.

**Special cases in CLI mode**:

| Operation | CLI mode | Editor (MCP) mode |
|-----------|----------|-------------------|
| Screenshots | Use `export_nodes({ nodeIds: [...], outputDir: "<path>", format: "png" })` — writes to disk. Then Read the exported PNG with the Read tool. | Use `get_screenshot(nodeId)` — returns image inline. |
| Batch reads | Combine multiple `batch_get` + `get_variables` calls in one heredoc | One MCP call per tool |
| Batch writes | Combine multiple `batch_design` calls in one heredoc (when independent) | One MCP call per tool |

When this skill says "Call `<tool_name>(...)`", execute it according to `$PENCIL_MODE`. Explicit CLI/MCP examples are only given where the modes diverge.

## Phase 0.5 — Pencil Availability Check

Before parsing arguments, verify that Pencil is reachable.

**CLI-app mode** (`$PENCIL_MODE` is `"cli-app"`):

1. Probe via Bash:
   ```bash
   pencil interactive -a desktop <<'EOF'
   get_editor_state({ include_schema: false })
   EOF
   ```
2. **If the call succeeds** → Pencil is available. Check the response for the currently active document file path and store it as `$PENCIL_OPEN_DOC` (set to the file path string if a document is open, or empty if no document is open). Proceed to argument parsing.
3. **If the call fails** → attempt auto-launch:
   a. Run `pencil &` to launch Pencil in the background, then retry the probe up to 3 times with 3-second pauses between attempts.
      - If a retry succeeds → proceed to argument parsing.
      - If all 3 retries fail → tell the user:
        "Pencil was launched but the CLI connection could not be established. Ensure Pencil is running and accepting CLI connections."
        **Stop.**

**Editor mode** (`$PENCIL_MODE` is `"editor"`):

1. Call `get_editor_state(include_schema: false)` as an MCP connectivity probe.
2. **If the call succeeds** → Pencil MCP is available. Store active document path as `$PENCIL_OPEN_DOC`. Proceed to argument parsing.
3. **If the call fails** → attempt auto-launch:
   a. Run `which pencil 2>/dev/null` to check if the `pencil` command is available.
   b. **If found**: Run `pencil &` to launch Pencil in the background, then retry `get_editor_state(include_schema: false)` up to 3 times with 3-second pauses between attempts.
      - If a retry succeeds → proceed to argument parsing.
      - If all 3 retries fail → tell the user:
        "Pencil was launched but the MCP connection could not be established. Check MCP server status in Pencil (View → MCP Server Status) and ensure the Pencil MCP server is listed in your Claude Code MCP configuration."
        **Stop.**
   c. **If not found**: Tell the user:
      "The Pencil editor is not running and the `pencil` command is not in PATH. Either:
      1. Open Pencil manually and ensure its MCP server is connected, or
      2. Install the `pencil` command from within the Pencil app (File → Install `pencil` command into PATH) for auto-launch support."
      **Stop.**

**Parse `$ARGUMENTS` — Mode Detection:**

Extract the first whitespace-delimited token from `$ARGUMENTS` and determine the mode:

- **If the first token matches `^\d+$` or `^#\d+$`** → **ticket mode**
  - Strip any `#` prefix to get the numeric ticket ID.
  - Everything after the first token is optional **user context** (additional instructions or focus areas).
  - Examples: `#1 focus on layout` → ID `1`, context `focus on layout`; `7` → ID `7`, no context.

- **Otherwise** → **ticketless mode**
  - The entire `$ARGUMENTS` string is the **design description**.
  - There is no ticket ID — the design description is the primary input.

**If ticket mode:** Fetch the ticket:

**Shell rules**: Read the `shell-rules` skill before running any `gh` commands (covers heredoc temp-file pattern).

Extract owner/repo from `git remote get-url origin` (e.g. `git@github.com:owner/repo.git` → `owner/repo`), then run:
```bash
gh issue view <number> --repo <owner>/<repo> --json number,title,body,labels,state,assignees,milestone,comments
```

Read the ticket body and look for a **Design Direction** section (produced by `/ccflow:refine` for frontend tickets). Store it for use in Phase 2.

**If ticketless mode:** Skip ticket fetching. The design description from `$ARGUMENTS` is the primary input.

Read `.claude/rules/lessons-learned.md` for any entries related to design or this feature area.

## Phase 1 — Attachments

**If ticketless mode:** Skip this section entirely and proceed to Phase 2.

**If ticket mode:** Read the `attachments` reference skill and follow its 4-step procedure to discover, present, download, and load ticket attachments. If no attachments are found or the user selects none, proceed to Phase 2.

## Phase 2 — Design Understanding

This is the forced reasoning phase. Do not create or modify any `.pen` files yet.

### Step 2A: Classify Design Type

Based on the ticket description (or design description in ticketless mode), classify what needs designing:

| Type | Examples |
|------|----------|
| **screen/page** | Settings page, profile page, checkout flow |
| **component** | Date picker, card, notification banner |
| **dashboard** | Analytics dashboard, admin panel |
| **landing-page** | Marketing page, product page, hero section |
| **form/wizard** | Multi-step form, signup wizard, onboarding |
| **slides/presentation** | Pitch deck, project update, onboarding slides |

### Step 2B: Retrieve Pencil Guidelines

Call `get_guidelines` with the topic most relevant to the classification:

| Design Type | Guideline Topic |
|-------------|----------------|
| landing-page | `landing-page` |
| dashboard, screen/page, form/wizard | `design-system` |
| component | `design-system` |
| slides/presentation | `slides` |

### Step 2C: Get Style Inspiration

1. Call `get_guidelines({ category: "style" })` to list available styles
2. Select the style that best matches the design task based on classification and context
3. Call `get_guidelines({ category: "style", name: "<selected-style>" })` to load the full style definition (pass any required `params` if the style requests them)

### Step 2D: Iterative Propose-First Questioning

Ask questions one at a time using `AskUserQuestion`. Propose specific answers rather than asking open-ended questions. Limit to 3–5 questions total. Skip any question already answered by the ticket's Design Direction section.

**Question 1 — Scope validation:**
> "Based on [the ticket / your description], I'll design [specific thing] containing [proposed elements]. Does this match your expectations?"

Options: "Yes, that's right", "Adjust scope" (+ description field)

**Question 2 — Design system discovery:**

- If the user specified a `.pen` file path in `$ARGUMENTS`, skip scanning and use that file directly.
- Otherwise, first check the configured `designPath` for existing `.pen` files using Glob (`<designPath>/*.pen`).
- If no `.pen` files found in `designPath`, fall back to a repo-wide scan: Glob (`**/*.pen`).

Then:
- If **no `.pen` files found** → designing from scratch. Mention this to the user.
- If **exactly one `.pen` file found** → propose using it: "Found existing design file `<path>`. Should I use its components as the design system?"
- If **multiple `.pen` files found** → present via `AskUserQuestion`:
  > "Found N design files. Which should I use as the design system (or start fresh)?"
  Options: one per `.pen` file path, plus "Start fresh (no design system)"

If using an existing `.pen` file:
- **If `$PENCIL_OPEN_DOC` is empty** (no document currently open) → call `open_document` with the `.pen` file path, then read its reusable components with `batch_get` using `{reusable: true}` to understand what's available.
- **If `$PENCIL_OPEN_DOC` is set** (a document is already open) → do **NOT** call `open_document` (calling it with an editor already open spawns a new Pencil instance and disconnects the MCP server). Instead, ask the user via `AskUserQuestion`:
  > "Pencil already has `<$PENCIL_OPEN_DOC>` open. Please switch to `<target .pen file>` in Pencil (File → Open), then confirm here."
  Options: "Done, file is open", "Cancel"
  - If **"Done"** → call `get_editor_state(include_schema: false)` to confirm the correct file is now open and update `$PENCIL_OPEN_DOC`. Then read its reusable components with `batch_get` using `{reusable: true}`.
  - If **"Cancel"** → skip design system loading and proceed as if designing from scratch.

**Question 3 — Visual direction:**

If the ticket has a **Design Direction** section from `/ccflow:refine`, propose using it:
> "The ticket specifies this design direction: [summary]. I'll follow this. Any adjustments?"

If no Design Direction exists, propose a direction from the style guide:
> "Based on the style guide, I'd suggest [specific aesthetic tone, e.g., 'editorial with high-contrast typography and generous whitespace']. Does this work, or do you have a different direction?"

Options: "Use this direction", "Different direction" (+ description field)

**Question 4 — Screen states** (conditional — only for screens/pages/forms):
> "Which states should I design? I'd suggest [empty, populated, error] at minimum."

Options (multiSelect=true): "Empty state", "Populated / default", "Error state", "Loading state"

**Question 5 — Responsive** (conditional — only for screens/pages/landing pages):
> "Desktop only, or should I also design for mobile/tablet?"

Options: "Desktop only", "Desktop + Mobile", "Desktop + Tablet + Mobile"

## Phase 2.5 — Branch Setup

After all design questions are answered, create a feature branch before any file creation or modification.

**Why not a worktree?** Pencil resolves file paths within its editor. Worktree paths (`.worktrees/<name>/...`) can cause issues with saves, autosaves, and MCP file operations. The design skill works directly in the main worktree on a feature branch instead.

### Step 2.5A: Ensure HEAD exists

```bash
git rev-parse HEAD 2>/dev/null
```
If this fails (no commits exist), create an initial commit:
```bash
git add -A && git commit -m "chore: initial commit" --allow-empty
```

### Step 2.5B: Create feature branch

- **If ticket mode:**
  ```bash
  git checkout -b feature/<ticket-id>-design
  ```
- **If ticketless mode:** Derive a slug from the design description (lowercase, hyphens, max 30 chars):
  ```bash
  git checkout -b feature/<auto-slug>-design
  ```

### Step 2.5C: Prepare design directory

```bash
mkdir -p <designPath>
```

## Phase 3 — Design Creation

Now create the design using Pencil tools. **All file paths in this phase must be absolute paths** within the repository root.

### Step 3A: Open or Create `.pen` File

First, call `get_editor_state(include_schema: false)` and update `$PENCIL_OPEN_DOC` from the response (the document may have changed since Phase 0.5, e.g., user switched files during Phase 2).

**If `$PENCIL_OPEN_DOC` is empty** (no document currently open):
- If a design system `.pen` file was selected in Phase 2 → call `open_document` with the **absolute path** of the `.pen` file (e.g., `<repo-root>/<designPath>/<file>.pen`). Use `get_editor_state` to confirm.
- If designing from scratch → call `open_document` with `"new"` to create a new empty document. After creation, the file will be saved to `<designPath>`.

**If `$PENCIL_OPEN_DOC` is set** (a document is already open):
- Determine the **target file**: the design system `.pen` file path or `"new"` (if designing from scratch).
- If `$PENCIL_OPEN_DOC` already matches the target file path → no action needed, proceed.
- Otherwise → do **NOT** call `open_document` (calling it with an editor already open spawns a new Pencil instance and breaks the connection). Ask the user via `AskUserQuestion`:
  > "Pencil already has `<$PENCIL_OPEN_DOC>` open. I need to open `<target file or 'a new document'>` instead. Please close the current file in Pencil (File → Close) or switch to the target file (File → Open), then confirm here."
  Options: "Done, ready to proceed", "Cancel design"
  - If **"Done"** → call `get_editor_state(include_schema: false)` to verify. Update `$PENCIL_OPEN_DOC`.
    - If the user closed the file (no document open) → now safe to call `open_document` with the target path or `"new"`.
    - If the user opened the correct target file → proceed without calling `open_document`.
    - If the wrong file is still open → ask again (loop once, then stop with an error if still wrong).
  - If **"Cancel design"** → **Stop.**

**Important (editor mode only)**: Pass the explicit `filePath` parameter pointing into the repository for all subsequent Pencil MCP tool calls. In CLI mode, the file path is managed by the Pencil desktop app and does not need to be passed explicitly.

### Step 3B: Get Editor State

Call `get_editor_state` with `include_schema: true` to understand the document structure and schema.

### Step 3C: Load Design System Components

If a design system file was selected:
- Call `batch_get` with `patterns: [{reusable: true}]` and `readDepth: 2` to discover all reusable components
- Catalog available components (buttons, inputs, cards, navigation, etc.) for use in the design

### Step 3D: Build the Design

Use `batch_design` to create the design. Follow these rules:

- **Max 25 operations per `batch_design` call** — split larger designs into multiple calls by logical section (e.g., header first, then content area, then footer)
- Use reusable components from the design system where available (insert as `type: "ref"`)
- For new elements not in the design system, create frames and text nodes directly
- Apply styling from the style guide and Design Direction
- Use `find_empty_space_on_canvas` when positioning new screens to avoid overlapping existing content
- Generate images with the `G()` operation where needed (hero images, avatars, illustrations)
- Set theme variables via `set_variables` if creating a new design system or extending an existing one
- Use absolute positioning within flex layouts for floating elements (FABs, modals, overlays, tooltips)

**Build order:**
1. Create the screen/page frame with overall layout
2. Add structural sections (header, sidebar, content area, footer)
3. Populate each section with components and content
4. Apply typography, colors, spacing, and other styling
5. Add images and decorative elements
6. Create additional screen states if requested (empty, error, loading)

### Step 3E: Responsive Variants

If the user requested responsive designs:
1. Find empty space on the canvas to the right of the desktop design
2. Create mobile (375px wide) and/or tablet (768px wide) variants
3. Adapt the layout for each breakpoint (stack columns, resize elements, hide secondary content)

## Phase 4 — Visual Validation Loop

### Step 4A: Screenshot and Inspect

For each screen/component created:

1. Capture a visual snapshot:
   - **CLI mode**: Call `export_nodes` to save screenshots to disk, then Read the exported PNG:
     ```bash
     pencil interactive -a desktop <<'EOF'
     export_nodes({ nodeIds: ["<node-id>"], outputDir: "$WORKTREE_PATH/<designPath>/screenshots", format: "png" })
     snapshot_layout({ parentId: "<node-id>", problemsOnly: true })
     EOF
     ```
     Then: `Read("$WORKTREE_PATH/<designPath>/screenshots/<node-id>.png")` to view and analyze.
   - **Editor mode**: Call `get_screenshot(nodeId)` to receive the image inline.
2. **Analyze the screenshot** for:
   - Alignment issues (elements not lined up properly)
   - Readability problems (text too small, low contrast)
   - Visual hierarchy (clear headings, proper spacing, content grouping)
   - Completeness (all specified elements present)
   - Clipping (content cut off or overflowing)
3. Review `snapshot_layout` output (captured alongside the screenshot) for programmatic layout problems
4. Fix any issues found via additional `batch_design` calls
5. Re-screenshot after fixes to confirm they resolved the problems

### Step 4B: Present to User

After validation passes, present the design to the user via `AskUserQuestion`:

> "Here's the design for [description]. I've verified alignment, readability, and completeness. What do you think?"

Options:
- **"Approve"** — proceed to Phase 5
- **"Request Changes"** — describe what to change
- **"Start Over"** — redesign from scratch

If **"Request Changes"**:
1. Ask what needs changing (via `AskUserQuestion` if the user didn't specify inline)
2. Apply the requested changes via `batch_design`
3. Re-screenshot and re-validate (loop back to Step 4A)
4. Re-present the updated design (back to Step 4B)

If **"Start Over"**:
1. Delete the current design from the canvas
2. Loop back to Phase 2, Question 3 (visual direction) to take a new direction
3. Rebuild from Phase 3

**Only proceed to Phase 5 after the user selects "Approve".**

## Phase 5.5 — Generate DESIGN.md

After the user approves the design in Phase 4, generate a `DESIGN.md` spec that documents the design for implementation.

### Step A: Extract data from .pen file

In CLI mode, batch all reads into a single invocation:

```bash
pencil interactive -a desktop <<'EOF'
batch_get({ patterns: [{ name: "Screen/.*" }] })
batch_get({ patterns: [{ reusable: true }], readDepth: 2 })
batch_get({ patterns: [{ name: "Note:.*" }] })
get_variables()
EOF
```

In editor mode, call each tool separately via MCP.

Parse the output into:

1. **Screens**: From the `Screen/.*` results — extract name, node ID. Derive route from the screen name (e.g., `Screen/training-plan` → `/training-plan`). Add a brief description based on the screen content.
2. **Components**: From the `reusable: true` results — extract name, node ID. Derive the framework component name from the Pencil component name (e.g., `Component/ExerciseCard` → `ExerciseCardComponent` for Angular, `ExerciseCard` for React). Determine UI library usage (e.g., PrimeNG, Material UI, custom) from component structure. Note which screens use each component.
3. **Annotations**: From the `Note:.*` results — extract name, node ID, and topic from the note content.
4. **Tokens**: From `get_variables()` — categorize variables into Colors, Typography, Radii, and Spacing. Map each to a CSS custom property name (e.g., `$bg-card` → `--bg-card`).

### Step B: Detect framework from config

Read `stack.frontend` (or per-project stack) from `.claude/config.json` to determine:
- Column headers for the Components table (Angular, React, Vue, or Generic)
- Component naming conventions (e.g., `<Name>Component` for Angular, `<Name>` for React)

### Step C: Write DESIGN.md

Use the template at `${CLAUDE_PLUGIN_ROOT}/templates/design-spec.md` as the base. Fill all parameterized sections with extracted data:
- Replace `<design-path>` with the configured `designPath`
- Replace `<pen-file-name>` with the actual `.pen` file name
- Replace `<framework>` and select the matching Components table variant
- Populate Screens, Components, Annotations, and Design Tokens tables with extracted data
- Write the completed file to `<designPath>/DESIGN.md`

**If `DESIGN.md` already exists** at that path, ask the user via `AskUserQuestion`:
> "A DESIGN.md already exists at `<designPath>/DESIGN.md`. What should I do?"

Options: "Overwrite with new spec", "Merge (add new entries, keep existing)"

- **Overwrite**: Replace the file entirely.
- **Merge**: Read the existing file, add new screens/components/tokens that don't already exist, preserve existing entries.

### Step D: Update ticket body (ticket mode only)

**If ticketless mode:** Skip this step.

**If ticket mode:** Append a `### Design Reference` section to the ticket body:
```bash
gh issue edit <number> --repo <owner>/<repo> --body "$UPDATED_BODY"
```
Where the updated body appends:
```
### Design Reference
- Design file: `<designPath>/<pen-file-name>`
- Design spec: `<designPath>/DESIGN.md`
```

## Phase 5 — Report Summary

### Report

Summarize what was created:
- `.pen` file path(s) created or modified
- Screens/components designed (list each with a brief description)
- Key design decisions (aesthetic tone, color palette, typography, layout approach)
- Design system components used (if any)
- `DESIGN.md` path, screen count, component count, token count

Include this note at the end of the report:
> "Note: The design file remains open in Pencil. Close it manually when done reviewing."

### Label "Working" (at start)

**If ticketless mode:** Skip this.

**If ticket mode:** Before starting design work (at the beginning of Phase 2), add the "Working" label:
```bash
gh issue edit <number> --repo <owner>/<repo> --add-label "Working"
```

## Phase 6 — Create PR

After Phase 5 reporting is complete, create a pull request containing the design artifacts.

### Step 6A: Capture Design Screenshots

```bash
mkdir -p $WORKTREE_PATH/<designPath>/screenshots
```

**CLI mode**: Export all screens in a single call:
```bash
pencil interactive -a desktop <<'EOF'
export_nodes({ nodeIds: ["<id1>", "<id2>", ...], outputDir: "$WORKTREE_PATH/<designPath>/screenshots", format: "png" })
EOF
```
Files are written as `<node-id>.png`. Rename them to human-readable names:
```bash
mv $WORKTREE_PATH/<designPath>/screenshots/<node-id>.png $WORKTREE_PATH/<designPath>/screenshots/<screen-name>.png
```

**Editor mode**: Export all screens via the `export_nodes` MCP tool:
Call `export_nodes` with `filePath`, `nodeIds` (all screen/component IDs), `outputDir: "$WORKTREE_PATH/<designPath>/screenshots"`, and `format: "png"`. Files are written as `<node-id>.png`. Rename them to human-readable names:
```bash
mv $WORKTREE_PATH/<designPath>/screenshots/<node-id>.png $WORKTREE_PATH/<designPath>/screenshots/<screen-name>.png
```

**Slides/presentation PDF export**: If the design type is `slides/presentation`, also export a combined PDF:
- **CLI mode**: `export_nodes({ nodeIds: [<all-slide-ids>], outputDir: "$WORKTREE_PATH/<designPath>/screenshots", format: "pdf" })` — all slides are combined into a single multi-page PDF.
- **Editor mode**: Call `export_nodes` with `format: "pdf"` and all slide node IDs. The tool combines them into one PDF document.

**Both modes**: If screenshots cannot be saved to files, prepare textual descriptions of each screen for the PR body instead. For each screen, write a brief textual description (2–3 sentences) covering layout, key elements, and visual style — these go in the PR body regardless of whether image files are available.

### Step 6B: Commit

Stage and commit all design artifacts:

```bash
git add <designPath>/ && git commit -m "feat(design): <description>"
```

- **If ticket mode:** Include ticket ref in the commit body: `#<ticket-id>`
- **If ticketless mode:** Use the design description slug in the commit message

### Step 6C: Push

Push the branch to the remote:

```bash
git push -u origin feature/<branch-name>
```

**If push fails** (sandbox network restriction or auth issue):
- Display the exact push command to the user
- Ask the user to run it manually and confirm when done
- Do not retry automatically

### Step 6D: Create PR

**Shell rules**: Use the temp-file pattern from the `shell-rules` skill — no heredocs.

1. Write the PR body to a temp file:

```bash
printf '%s' '<pr-body-content>' > /tmp/claude/design-pr-body.md
```

**PR body template:**

```markdown
## Summary
<1-3 bullet points describing the design>

## Ticket
<ticket-mode only: Closes #<ticket-id>>

## Design Files
- Design file: `<designPath>/<pen-file-name>`
- Design spec: `<designPath>/DESIGN.md`

## Design Preview
<For each screen: textual description. If screenshot files were committed, also include:>
![<Screen Name>](<designPath>/screenshots/<screen-name>.png)

## Screens Designed
<Bulleted list of each screen/component with brief description>

## Design Decisions
<Key choices: aesthetic tone, color palette, typography, layout approach, component library>

## Notes
<Any caveats, open questions, or implementation guidance>

🎨 Generated with [Claude Code](https://claude.com/claude-code) using ccflow design skill
```

2. Create the PR:

```bash
BODY=$(cat /tmp/claude/design-pr-body.md) && gh pr create --title "feat(design): <short-description>" --body "$BODY" --repo <owner>/<repo>
```

### Step 6E: Label Ticket

**If ticketless mode:** Skip labeling.

**If ticket mode:** Replace "Working" with "Designed":
```bash
gh issue edit <number> --repo <owner>/<repo> --add-label "Designed" --remove-label "Working"
```

### Step 6F: Error Recovery

- **Push fails** → Display command, ask user to push manually (covered in Step 6C)
- **PR creation fails** → Retry once. If it fails again, display the `gh pr create` command for the user to run manually
- **Branch already exists** → Ask via `AskUserQuestion`: "Branch `feature/<name>` already exists. Reuse it or recreate?" Options: "Reuse existing (checkout)", "Delete and recreate"

## After PR

Switch back to `main`:
```bash
git checkout main
```

Report the PR URL to the user. Then **STOP.** Do not:
- Enter plan mode or propose an implementation plan
- Offer to run `/implement` or start implementation
- Suggest next steps beyond telling the user to run `/ccflow:implement` when ready

Tell the user: "Design PR created: `<PR-URL>`. Run `/ccflow:implement <ticket-id>` when ready to implement."
