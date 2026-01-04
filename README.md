# Pi Swarm 🐝

Parallel GitHub issue and PR processing using the `pi` agent and Git worktrees.

## Features

- **Issue Swarm**: Process multiple GitHub issues in parallel.
- **PR Swarm**: Review and automatically fix multiple Pull Requests in parallel.
- **Isolated Worktrees**: Each agent works in its own `git worktree` to avoid file conflicts.
- **Headless Execution**: Uses `pi --mode json` for structured monitoring.
- **Automatic Commits**: Instructs the agent to commit its work and verifies before completion.
- **PR Creation**: Automatically creates PRs from issue branches.

## Installation

1. Ensure you have the following dependencies:
   - [gh CLI](https://cli.github.com/) (authenticated)
   - [jq](https://stedolan.github.io/jq/)
   - `pi` agent installed
   - `git`

2. Clone this repository or add it to your agent's skills.

## Usage

> [!IMPORTANT]
> Always run these scripts from the root of the repository you want to process issues or PRs for.

### Working on Issues

Process specific issues by number:
```bash
~/.config/agents/skills/pi-swarm/scripts/swarm.sh 12 15 22
```

### Reviewing PRs

Review and fix specific PRs:
```bash
~/.config/agents/skills/pi-swarm/scripts/pr-swarm.sh 101 105
```

## Options

Most scripts support these common flags:

- `--model <name>`: Specify the model (e.g., `sonnet`, `opus`).
- `--jobs <n>`: Limit concurrent jobs.
- `--timeout <min>`: Set a timeout per task.
- `--no-push`: Don't push changes to remote.
- `--dry-run`: Preview actions without executing.

## Monitoring

Logs for each task are stored in `.worktrees/`:
- `issue-<number>.log`: Readable output log.
- `issue-<number>.jsonl`: Structured JSON log from the agent.

Watch progress:
```bash
tail -f .worktrees/*.log
```
