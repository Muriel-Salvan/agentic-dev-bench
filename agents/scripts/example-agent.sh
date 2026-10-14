#!/usr/bin/env bash
#
# Example agent script for the repo-local bash-script Harbor agent
# (bash_script_agent.agent:BashScriptAgent).
#
# Contract (see agents/scripts/README.md):
#   * The scenario's `model` value points at this file, relative to the
#     repository root.
#   * Runs inside the task container as the agent user, in /workspace
#     (the cloned sandbox repository), with `git` and authenticated `gh`
#     ready.
#   * The task prompt is in the INSTRUCTION environment variable.
#   * Exit 0 only when the agent considers the task done; any non-zero exit
#     fails the trial (the separate verifier still decides the final reward).

set -euo pipefail

echo "example-agent: no real agent implemented yet"
echo "example-agent: instruction was: ${INSTRUCTION:-<missing INSTRUCTION env var>}"

# Deliberate failure: an unimplemented placeholder must never look like a
# successful agent run in benchmark results.
exit 1
