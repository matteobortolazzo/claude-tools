# Project: <name>

Monorepo with <N> projects. <ticket-system> for tracking. <pr-system> for PRs.

## Critical Rules
- ALWAYS read the CLAUDE.md in the project directory you are working in.
- Read `.claude/rules/` files for repo-wide conventions.
- Test-first: integration tests that assert behavior, not implementation details.
- Keep tickets well-scoped. 1 ticket = 1 PR.
- Use git worktrees for all feature work. Never modify code in main worktree.

## Projects
| Directory | Stack | Description |
|-----------|-------|-------------|
| `<path>` | <stack> | <description> |

<!-- IF pencil.enabled AND pencil.shared -->
## Design Files (shared)
- Design spec: `<designPath>/DESIGN.md` — screens, components, tokens, naming conventions
- Design file: `<designPath>/<name>.pen` — open in Pencil, read with Pencil MCP tools
- ALWAYS read DESIGN.md before implementing any frontend feature
<!-- END IF -->
<!-- IF pencil.enabled AND NOT pencil.shared -->
## Design Files
Each frontend project has its own design directory. See per-project CLAUDE.md for paths.
- ALWAYS read the project's DESIGN.md before implementing any frontend feature
<!-- END IF -->

## Rule Files
See `.claude/rules/` for conventions:
- `lessons-learned.md` — real mistakes from this codebase (authoritative)
- Other rule files as created by the team
