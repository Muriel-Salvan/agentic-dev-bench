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
    * cwd is ``/workspace`` (the cloned sandbox repository).
    * The task prompt is available in the ``INSTRUCTION`` environment
      variable.
    * A non-zero exit code fails the trial (Harbor raises
      ``NonZeroAgentExitCodeError``); the scenario's separate verifier still
      decides the final reward.
    """

    # Where the script lands inside the task container. Chosen under
    # /installed-agent, the directory BaseInstalledAgent#setup creates for
    # every installed agent.
    REMOTE_SCRIPT_PATH = "/installed-agent/agent.sh"

    # Working directory the script runs in (the cloned sandbox repository).
    WORKDIR = "/workspace"

    @staticmethod
    def name() -> str:
        return "bash-script"

    def version(self) -> str | None:
        return None

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
            command=f"bash {shlex.quote(self.REMOTE_SCRIPT_PATH)}",
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