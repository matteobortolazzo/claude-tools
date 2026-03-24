<!-- Single-project template. For monorepos, use claude-md-root-monorepo.md instead. -->

# Project: <name>

<backend-stack> backend + <frontend-stack> frontend.
<ticket-system> for tracking. <pr-system> for code and PRs.

## Critical Rules
- ALWAYS read relevant `.claude/rules/` files before working on any layer.
- Test-first: integration tests that assert behavior, not implementation details.
- Keep tickets well-scoped. 1 ticket = 1 PR.
- Use git worktrees for all feature work. Never modify code in main worktree.

<!-- IF pencil.enabled -->
## Design Files
- Design spec: `<designPath>/DESIGN.md` — screens, components, tokens, naming conventions
- Design file: `<designPath>/<name>.pen` — open in Pencil, read with Pencil MCP tools
- ALWAYS read DESIGN.md before implementing any frontend feature
<!-- END IF -->

## Rule Files
See `.claude/rules/` for conventions:
- `lessons-learned.md` — real mistakes from this codebase (authoritative, overrides assumptions)
- Other rule files as created by the team
