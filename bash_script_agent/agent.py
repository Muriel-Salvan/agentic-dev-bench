"""Repo-local Harbor custom agent that runs a bash script as the agent.

Harbor resolves custom agents passed to ``--agent`` as ``module.path:Class``
import paths (any name containing ``:`` that is not a catalog name), so
scenarios reference this agent as::

    agent:
      name: bash_script_agent.agent:BashScriptAgent
      model: agents/scripts/my-agent.sh

The scenario's ``model`` value is the path to the bash script implementing
the agent, relative to the repository root. ``HarborRunner`` resolves it to
an absolute host path before invoking Harbor; the script is uploaded into
the task container and executed as the agent user.
"""

import os
import shlex
import tempfile
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class BashScriptAgent(BaseInstalledAgent):
    """Runs an arbitrary bash script as the benchmark agent.

    Contract with the script:

    * Uploaded to the container with CRLF line endings normalized to LF
      (the benchmark repository is developed on Windows).
    * Executed as ``bash /installed-agent/agent.sh`` as the agent user.
    * cwd is ``/workspace/repo`` (the cloned GitHub sandbox repository).
    * The task prompt is available in the ``INSTRUCTION`` environment
      variable.
    * A non-zero exit code fails the trial (Harbor raises
      ``NonZeroAgentExitCodeError``); the scenario's separate verifier still
      decides the final reward.

    Failure-output handling (Harbor truncates exec output to 1000 chars in
    ``NonZeroAgentExitCodeError`` messages, which end up ellipsized in
    ``exception.txt``/``result.json``):

    * The script's combined stdout/stderr is additionally tee'd to
      ``agent-output.log`` in the container's agent-log mount
      (``/logs/agent``, i.e. ``<trial>/agent/`` on the host). Harbor
      downloads that directory after the run even on failure, so the full
      transcript always survives there.
    * The in-message truncation cap is raised (see ``_truncate_output``) so
      ``exception.txt`` itself stays complete for realistically sized
      output.
    """

    # Where the script lands inside the task container. Chosen under
    # /installed-agent, the directory BaseInstalledAgent#setup creates for
    # every installed agent.
    REMOTE_SCRIPT_PATH = "/installed-agent/agent.sh"

    # Container WORKDIR is /workspace/repo: that is where adb-entrypoint.sh
    # clones the GitHub sandbox repository (see Dockerfile.erb WORKDIR).
    WORKDIR = "/workspace/repo"

    # Name of the full-transcript file written into the container's
    # agent-log mount (``self.environment_logs_dir``, i.e. ``/logs/agent``
    # -> ``<trial>/agent/`` on the host).
    OUTPUT_LOG_NAME = "agent-output.log"

    # Harbor's BaseInstalledAgent truncates exec output to 1000 chars in
    # failure messages. Keep the head+tail behavior but allow much more
    # before truncating; the full transcript is always in OUTPUT_LOG_NAME.
    DEFAULT_MAX_OUTPUT_CHARS = 100_000

    # Environment variable (agent extra_env or host env) overriding
    # DEFAULT_MAX_OUTPUT_CHARS.
    MAX_OUTPUT_ENV_VAR = "BASH_SCRIPT_AGENT_MAX_OUTPUT"

    @staticmethod
    def name() -> str:
        return "bash-script"

    def version(self) -> str | None:
        return None

    def _max_output_chars(self) -> int:
        """Resolve the in-message output cap, honoring MAX_OUTPUT_ENV_VAR."""
        try:
            raw = self._get_env(self.MAX_OUTPUT_ENV_VAR)
        except AttributeError:
            # Partially constructed instance (e.g. direct unit-test use
            # without Harbor's __init__); fall back to the default cap.
            return self.DEFAULT_MAX_OUTPUT_CHARS
        if raw is not None:
            try:
                limit = int(raw)
            except (TypeError, ValueError):
                limit = 0
            if limit > 0:
                return limit
        return self.DEFAULT_MAX_OUTPUT_CHARS

    def _truncate_output(
        self, text: str | None, max_len: int | None = None
    ) -> str:
        """Like Harbor's, but with a much larger default cap.

        Harbor always calls this without ``max_len``; an explicitly passed
        value is still honored.
        """
        if not text:
            return "None"
        limit = max_len if max_len is not None else self._max_output_chars()
        if len(text) <= limit:
            return text
        # Keep the tail as well as the head: agents emit boilerplate first
        # and report the actual failure at the end of the stream.
        head_len = limit // 4
        tail_len = limit - head_len
        omitted = len(text) - head_len - tail_len
        return (
            f"{text[:head_len]} ... [{omitted} chars truncated] "
            f"... {text[-tail_len:]}"
        )

    def _agent_command(self) -> str:
        """Run the script while teeing the full transcript to the log mount.

        Merges stderr into stdout and tees everything to OUTPUT_LOG_NAME in
        the agent-log mount (synced to ``<trial>/agent/`` on the host even
        on failure). ``PIPESTATUS[0]`` preserves the script's exit code
        through the pipe (Harbor prepends ``set -o pipefail;`` itself, so
        the reference is valid in the remote shell).
        """
        log_dir = self.environment_logs_dir.as_posix()
        log_path = (self.environment_logs_dir / self.OUTPUT_LOG_NAME).as_posix()
        return (
            f"mkdir -p {shlex.quote(log_dir)} && "
            f"bash {shlex.quote(self.REMOTE_SCRIPT_PATH)} 2>&1 | "
            f"tee {shlex.quote(log_path)}; "
            'exit "${PIPESTATUS[0]}"'
        )

    async def install(self, environment: BaseEnvironment) -> None:
        # Nothing to install: the agent script itself is uploaded in run().
        return None

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        script = self._resolve_script()
        with tempfile.TemporaryDirectory(prefix="bash-script-agent-") as temp_dir:
            normalized = Path(temp_dir) / script.name
            # write_bytes (not write_text) so Windows newline translation
            # cannot reintroduce CRLF after normalization.
            normalized.write_bytes(
                script.read_bytes()
                .decode("utf-8-sig")
                .replace("\r\n", "\n")
                .replace("\r", "\n")
                .encode("utf-8")
            )
            await self._upload_agent_owned_file(
                environment, normalized, self.REMOTE_SCRIPT_PATH
            )
        await self.exec_as_agent(
            environment,
            command=self._agent_command(),
            env={"INSTRUCTION": instruction},
            cwd=self.WORKDIR,
        )

    def _resolve_script(self) -> Path:
        """Resolve the scenario's model value to the agent script on disk."""
        if not self.model_name:
            raise ValueError(
                "bash_script_agent.agent:BashScriptAgent requires the "
                "scenario's agent.model to be the path to a bash script "
                "(e.g. agents/scripts/example-agent.sh)"
            )
        path = Path(self.model_name)
        if not path.is_absolute():
            # HarborRunner passes absolute paths; relative paths only occur
            # when `harbor run` is invoked manually from the repository root.
            path = Path.cwd() / path
        if not path.is_file():
            raise ValueError(f"Agent script not found: {path}")
        return path