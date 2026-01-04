---
name: pi-swarm
description: Spawns parallel pi agents to work on multiple GitHub issues or PRs using git worktrees. Use when asked to process multiple items in parallel or perform bulk reviews/fixes.
---

# Pi Swarm

Orchestrates parallel headless pi agents across isolated git worktrees to process multiple GitHub issues or PRs simultaneously.

## Usage

### Issue Swarm
Process multiple issues in parallel:
```bash
scripts/swarm.sh 48 50 52
```

### PR Swarm
Review and fix multiple PRs in parallel:
```bash
scripts/pr-swarm.sh 101 105
```

## What It Does

For each item (Issue or PR):

1. **Fetches** details (title, body, comments) from GitHub API.
2. **Creates** a dedicated git worktree in `.worktrees/`.
3. **Isolates** work in a specific branch.
4. **Spawns** a headless `pi` agent with a structured prompt.
5. **Monitors** progress and captures logs in JSONL format.
6. **Commits** changes and optionally pushes/creates PRs or comments.

All tasks run in **parallel** with configurable concurrency limits.

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--model <name>` | Model to use (sonnet, opus, etc.) | (default) |
| `--push` / `--no-push` | Push changes to remote | enabled |
| `--pr` / `--no-pr` | Create PRs (for `swarm.sh`) | enabled |
| `--cleanup` / `--no-cleanup` | Delete worktrees after success | enabled |
| `-j, --jobs <n>` | Max parallel jobs | unlimited |
| `--timeout <min>` | Timeout per task in minutes | no timeout |
| `--dry-run` | Preview actions without executing | disabled |

## Requirements

- `gh` CLI authenticated
- `jq` for JSON parsing
- `pi` agent installed
- Git repository with GitHub remote

## Monitoring

Watch real-time logs:
```bash
tail -f .worktrees/*.log
```

## Output Structure

```
.worktrees/
├── issue-48/           # Isolated worktree
├── issue-48.log        # Human-readable log
├── issue-48.jsonl      # Structured agent log
└── ...
```
