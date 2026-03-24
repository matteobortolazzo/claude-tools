---
name: worktrees
description: Git worktree patterns for isolated parallel development. Use when creating feature branches, managing git worktrees, isolating feature work, parallel development, setting up a worktree, listing worktrees, worktree naming conventions, or cleaning up worktrees.
user-invocable: false
---

## Structure
```
project-root/          # Main worktree — stays on main, read-only for implementation
├── .worktrees/        # All feature worktrees (gitignored)
│   ├── 12345-feature-a/
│   └── 12346-feature-b/
```

## Rules
- **Never modify code in main worktree** — use it for reading/searching/comparing
- **One worktree per feature** (enables parallel Claude Code instances)
- **Naming**: `.worktrees/<ticket-id>-<short-description>`

## Commands
```bash
# Create worktree for a feature
git worktree add .worktrees/<id>-<desc> -b feature/<id>-<desc>

# List worktrees
git worktree list
```

## .gitignore
Ensure `.worktrees/` is in `.gitignore`.
