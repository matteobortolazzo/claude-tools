---
name: design
description: Interactive design reasoning and .pen file creation using Pencil
argument-hint: <ticket-id | design description> [additional context]
user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion, WebFetch, mcp__pencil__get_editor_state, mcp__pencil__get_guidelines, mcp__pencil__get_style_guide_tags, mcp__pencil__get_style_guide, mcp__pencil__batch_get, mcp__pencil__batch_design, mcp__pencil__get_screenshot, mcp__pencil__find_empty_space_on_canvas, mcp__pencil__snapshot_layout, mcp__pencil__open_document, mcp__pencil__get_variables, mcp__pencil__set_variables, mcp__pencil__replace_all_matching_properties, mcp__pencil__search_all_unique_properties
---

<!-- Architecture note: ccflow orchestrates Pencil via MCP (ccflow-driven model).
     We do NOT use `pencil --agent-config` because:
     1. ccflow needs ticket/worktree/approval workflow integration that agent-config agents lack
     2. agent-config agents have no ccflow context (config, rules, lessons-learned)
     3. For complex designs, we batch via multiple `batch_design` calls within one session
     The Pencil editor (or future headless mode) is always the MCP server, Claude Code is the client. -->

## Phase 0 — Context Loading

**Config check**: Before anything else, verify `.claude/config.json` exists by reading it. If the file does not exist, **stop immediately** and tell the user:
"ccflow is not configured for this project. Run `/ccflow:configure` first to set up."

Read `.claude/config.json`.

**Pencil gating**: Check `pencil.enabled` in `.claude/config.json`. If `pencil` is absent or `pencil.enabled` is not `true`, **stop immediately** and tell the user:
"Pencil design workflows are not enabled for this project. Run `/ccflow:configure` and enable Pencil when prompted."

Read `pencil.designPath` from the config to determine where design files belong. If the project is a monorepo with `pencil.shared: false`, determine the per-project `designPath` from the affected project's entry in the `projects` array.

## Phase 0.5 — MCP Availability Check

Before parsing arguments, verify that the Pencil MCP server is reachable.

Read `pencil.mode` from `.claude/config.json` (default: `"editor"` if not present).

**Editor mode** (`pencil.mode` is `"editor"` or absent):

1. Call `get_editor_state(include_schema: false)` as a connectivity probe.
2. **If the call succeeds** → Pencil MCP is available. Proceed to argument parsing.
3. **If the call fails** → attempt auto-launch:
   a. Run `which pencil 2>/dev/null` to check if the Pencil CLI is installed.
   b. **If CLI found**: Run `pencil &` to launch Pencil in the background, then retry `get_editor_state(include_schema: false)` up to 3 times with 3-second pauses between attempts.
      - If a retry succeeds → proceed to argument parsing.
      - If all 3 retries fail → tell the user:
        "Pencil was launched but the MCP connection could not be established. Check MCP server status in Pencil (View → MCP Server Status) and ensure the Pencil MCP server is listed in your Claude Code MCP configuration."
        **Stop.**
   c. **If CLI not found**: Tell the user:
      "The Pencil editor is not running and the `pencil` CLI is not installed. Either:
      1. Open Pencil manually and ensure its MCP server is connected, or
      2. Install the CLI (in Pencil: File → Install `pencil` command into PATH) for auto-launch support."
      **Stop.**

**Headless mode** (`pencil.mode` is `"headless"` — future):

1. Verify that a headless Pencil MCP server entry exists in `.mcp.json` (project or plugin scope).
2. Call `get_editor_state(include_schema: false)` as a probe.
3. If it fails → tell the user: "Headless Pencil MCP server is configured but not responding. Check your `.mcp.json` configuration." **Stop.**

**Auto mode** (`pencil.mode` is `"auto"` — future):

1. Try headless mode first (steps above).
2. If headless is not configured or fails → fall back to editor mode (steps above).

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

### Step 2B: Retrieve Pencil Guidelines

Call `get_guidelines` with the topic most relevant to the classification:

| Design Type | Guideline Topic |
|-------------|----------------|
| landing-page | `landing-page` |
| dashboard, screen/page, form/wizard | `design-system` |
| component | `design-system` |

### Step 2C: Get Style Inspiration

1. Call `get_style_guide_tags` to retrieve all available tags
2. Select 5–10 tags that best match the design task
3. Call `get_style_guide` with the selected tags

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

If using an existing `.pen` file, open it with `open_document` and read its reusable components with `batch_get` using `{reusable: true}` to understand what's available.

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

## Phase 2.5 — Worktree Setup

After all design questions are answered, create a git worktree before any file creation or modification.

### Step 2.5A: Ensure HEAD exists

```bash
git rev-parse HEAD 2>/dev/null
```
If this fails (no commits exist), create an initial commit:
```bash
git add -A && git commit -m "chore: initial commit" --allow-empty
```

### Step 2.5B: Create worktree

- **If ticket mode:**
  ```bash
  git worktree add .worktrees/<ticket-id>-design -b feature/<ticket-id>-design
  ```
- **If ticketless mode:** Derive a slug from the design description (lowercase, hyphens, max 30 chars):
  ```bash
  git worktree add .worktrees/<auto-slug>-design -b feature/<auto-slug>-design
  ```

Store the worktree path (e.g., `.worktrees/<id>-design`) as `$WORKTREE_PATH` for all subsequent phases.

### Step 2.5C: Prepare design directory in worktree

```bash
mkdir -p $WORKTREE_PATH/<designPath>
```

### Step 2.5D: Copy existing design system file (if applicable)

If a design system `.pen` file was selected in Phase 2, copy it into the worktree so Pencil opens the worktree copy:
```bash
cp <original-pen-file-path> $WORKTREE_PATH/<designPath>/
```

All subsequent phases operate on files inside `$WORKTREE_PATH`.

## Phase 3 — Design Creation

Now create the design using Pencil tools. **All file paths in this phase must be absolute paths inside the worktree** (`$WORKTREE_PATH`).

### Step 3A: Open or Create `.pen` File

- If a design system `.pen` file was copied to the worktree in Phase 2.5 → call `open_document` with the **absolute path** of the worktree copy (e.g., `<repo-root>/$WORKTREE_PATH/<designPath>/<file>.pen`). Use `get_editor_state` to confirm.
- If designing from scratch → call `open_document` with `"new"` to create a new empty document. After creation, the file will be saved to the worktree's `designPath`.

**Important**: Pass the explicit `filePath` parameter pointing into the worktree for all subsequent Pencil MCP tool calls (`batch_get`, `batch_design`, `get_screenshot`, `snapshot_layout`, `get_variables`, `set_variables`, etc.).

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

1. Call `get_screenshot` to capture a visual snapshot
2. **Analyze the screenshot** for:
   - Alignment issues (elements not lined up properly)
   - Readability problems (text too small, low contrast)
   - Visual hierarchy (clear headings, proper spacing, content grouping)
   - Completeness (all specified elements present)
   - Clipping (content cut off or overflowing)
3. Call `snapshot_layout` with `problemsOnly: true` to detect layout problems programmatically
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

1. **Screens**: `batch_get(patterns: [{name: "Screen/.*"}])` — extract name, node ID. Derive route from the screen name (e.g., `Screen/training-plan` → `/training-plan`). Add a brief description based on the screen content.
2. **Components**: `batch_get(patterns: [{reusable: true}], readDepth: 2)` — extract name, node ID. Derive the framework component name from the Pencil component name (e.g., `Component/ExerciseCard` → `ExerciseCardComponent` for Angular, `ExerciseCard` for React). Determine UI library usage (e.g., PrimeNG, Material UI, custom) from component structure. Note which screens use each component.
3. **Annotations**: `batch_get(patterns: [{name: "Note:.*"}])` — extract name, node ID, and topic from the note content.
4. **Tokens**: `get_variables()` — categorize variables into Colors, Typography, Radii, and Spacing. Map each to a CSS custom property name (e.g., `$bg-card` → `--bg-card`).

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
- Write the completed file to `$WORKTREE_PATH/<designPath>/DESIGN.md`

**If `DESIGN.md` already exists** at that path in the worktree, ask the user via `AskUserQuestion`:
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
> "Note: The design file remains open in Pencil. Close it manually when done reviewing. (Pencil's MCP does not currently provide a `close_document` tool.)"

### Label "Working" (at start)

**If ticketless mode:** Skip this.

**If ticket mode:** Before starting design work (at the beginning of Phase 2), add the "Working" label:
```bash
gh issue edit <number> --repo <owner>/<repo> --add-label "Working"
```

## Phase 6 — Create PR

After Phase 5 reporting is complete, create a pull request containing the design artifacts.

### Step 6A: Capture Design Screenshots

For each screen/component designed:

1. Call `get_screenshot` on the screen's node ID to capture a visual snapshot
2. Attempt to save the screenshot to the worktree:
   ```bash
   mkdir -p $WORKTREE_PATH/<designPath>/screenshots
   ```
3. If `get_screenshot` returns a file path → copy it:
   ```bash
   cp <screenshot-path> $WORKTREE_PATH/<designPath>/screenshots/<screen-name>.png
   ```
4. If `get_screenshot` returns base64 image data → decode it:
   ```bash
   echo '<base64-data>' | base64 -d > $WORKTREE_PATH/<designPath>/screenshots/<screen-name>.png
   ```
5. If screenshots cannot be saved to files (neither path nor base64 available), prepare textual descriptions of each screen for the PR body instead

For each screen, write a brief textual description (2–3 sentences) covering layout, key elements, and visual style — these go in the PR body regardless of whether image files are available.

### Step 6B: Commit

Stage and commit all design artifacts inside the worktree:

```bash
cd $WORKTREE_PATH && git add -A && git commit -m "feat(design): <description>"
```

- **If ticket mode:** Include ticket ref in the commit body: `#<ticket-id>`
- **If ticketless mode:** Use the design description slug in the commit message

### Step 6C: Push

Push the branch to the remote:

```bash
cd $WORKTREE_PATH && git push -u origin feature/<branch-name>
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
- **Worktree already exists** → Ask via `AskUserQuestion`: "A worktree already exists at `.worktrees/<name>`. Reuse it or recreate?" Options: "Reuse existing", "Delete and recreate"

## After PR

Report the PR URL to the user. Then **STOP.** Do not:
- Enter plan mode or propose an implementation plan
- Offer to run `/implement` or start implementation
- Suggest next steps beyond telling the user to run `/ccflow:implement` when ready

Tell the user: "Design PR created: `<PR-URL>`. Run `/ccflow:implement <ticket-id>` when ready to implement."
