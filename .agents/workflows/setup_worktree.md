---
description: Set up a new git worktree
---

# Setup Git Worktree Workflow

When you need an isolated environment for a new feature or bugfix, use this workflow to create a new git worktree that branches off the shared local `main` branch. 

## Parameters
- `<WORKTREE_NAME>`: The name of the new worktree folder and the new branch.

// turbo-all
## Steps

1. Ensure the shared local `main` branch is up to date (following the Git Rules).
```bash
git fetch fork main:main
```

2. Create the new worktree in the parent directory (`ruby-sidecar/`). This automatically creates a new branch with the same name, based off the synchronized local `main` branch.
```bash
git worktree add ../<WORKTREE_NAME> -b <WORKTREE_NAME> main
```
