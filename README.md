# agentic-dev-bench

Benchmarking AI agents on realistic software development workflows.

This first scaffold uses [Harbor](https://github.com/harbor-framework/harbor), Docker, and GitHub sandboxes. A scenario pins an existing public repository to a commit, creates a fresh private sandbox repository, creates an issue with the requirements, runs an agent through a Harbor adapter, and records run metrics.

## Requirements

- Ruby >= 3.2
- Docker
- Harbor installed and available as `harbor`
- A GitHub token that can create/delete repositories for the configured benchmark owner

## Setup

```bash
bundle install
export GITHUB_TOKEN=...
export GITHUB_OWNER=your-github-user-or-org
```

Before running the sample, replace the source repository and immutable commit in `scenarios/add-greeting.yml`. The sample task is intentionally a scaffold: use a repository whose language/test setup matches the requirements you want to benchmark.

## Run

```bash
bundle exec bin/agentic-dev-bench list
bundle exec bin/agentic-dev-bench execute scenarios/add-greeting.yml
bundle exec bin/agentic-dev-bench execute scenarios/add-greeting.yml --keep
```

Runs are stored below `runs/` and include the sandbox metadata, Harbor stdout/stderr, and `result.yml`. Successful runs are cleaned up automatically; `--keep` preserves the sandbox for inspection.

## Design

```text
Scenario YAML
     |
     v
GitHub sandbox -----> Issue
     |
     v
Harbor + Docker -----> Agent
     |
     v
Verifier / metrics
     |
     v
Run result + CLI
```

The benchmark definitions contain scenario inputs, not mutable GitHub state. Each run gets a unique sandbox repository, so previous runs cannot affect future runs.

## Next steps

The Harbor adapter is deliberately isolated because Harbor's CLI/API evolves. The next implementation step should align `HarborRunner` with the exact Harbor release being used, then add a proper verifier that runs inside the isolated environment and richer metrics such as tests passed, cost, token usage, commits, PR state, and review comments resolved.

## Security

Use a dedicated GitHub account or GitHub App with minimum required permissions. Do not give an agent credentials that can access unrelated repositories.
