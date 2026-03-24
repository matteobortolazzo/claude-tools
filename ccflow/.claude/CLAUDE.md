# Project: ccflow

Claude Code plugin — Markdown skills, JSON config, shell hooks.
GitHub Issues for tracking. GitHub for code and PRs.

## Critical Rules
- ALWAYS read relevant `.claude/rules/` files before working on any layer.
- Test-first: integration tests that assert behavior, not implementation details.
- Keep tickets well-scoped. 1 ticket = 1 PR.
- Use git worktrees for all feature work. Never modify code in main worktree.

## Rule Files
See `.claude/rules/` for conventions:
- `lessons-learned.md` — real mistakes from this codebase (authoritative, overrides assumptions)
- Other rule files as created by the team
