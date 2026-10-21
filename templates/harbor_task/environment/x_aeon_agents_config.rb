# X-Aeon Agents configuration for the Harbor task container.
#
# Rendered from templates/harbor_task/environment/ into the Docker build
# context by HarborRunner#write_task_files (same as Dockerfile and
# entrypoint.sh) and baked into the image at /etc/x_aeon_agents.rb, with
# X_AEON_AGENTS_CONFIG pointing at it (see Dockerfile). It lives under
# /etc -- NOT under /workspace -- because adb-entrypoint.sh wipes
# /workspace before cloning, so anything there would be deleted.
#
# data_dir lives under the AGENT log dir (/logs/agent), which Harbor
# bind-mounts to <trial>/agent/ on the host. That keeps the agent's
# session state OUT of /workspace (the repo, uploaded as an artifact into
# the separate verifier -- a deep sessions/... tree there breaks
# `docker compose cp` on Windows) AND out of /logs/artifacts. The latter
# matters just as much: /logs/artifacts is the convention publish dir that
# Harbor's upload_artifacts re-uploads into the verifier via `upload_dir`
# (docker compose cp -> tar fallback), so a deep/transient sessions tree
# there fails the same way on Windows. /logs/agent is synced to the host
# by chown only (prepare_logs_for_host) and is never uploaded, so it is
# both live on the host for debugging and safe.
data_dir '/logs/agent/xaa'

# Model selection: run the whole implement-issue pipeline (plan
# generator, coder, tester, documenter) plus the review-comments agents
# on Cline's free model, instead of the paid default
# (anthropic/claude-sonnet-4.6). The DSL has no global model setting:
# `configure_agent` registers a proc per agent class, and the returned
# hash is merged into the kwargs the class is initialized with. The
# classes below are all agents that drive the `cline` CLI.
%i[
  CoderAgent
  DocumenterAgent
  FeedbackAnalystAgent
  PlanGeneratorAgent
  ReviewResponderAgent
  TesterAgent
].each do |agent_class_name|
  configure_agent(agent_class_name) { { model: 'reflection/beam-free' } }
end

# The AiAgents helpers (diff interpreter, executor, one-line diff
# summarizer) talk to OpenRouter via RubyLLM and cannot resolve
# Cline-hosted model ids, so they use the free OpenRouter model
# instead. XAeonAgents::Config reads the key from ENV['OPENROUTER_API_KEY']
# and installs it into RubyLLM.config in setup_ai_agents, so no explicit
# key setter is needed here -- only the model.
%i[
  DiffInterpreterAgent
  ExecutorAgent
  OneLineCodeDiffSummarizerAgent
].each do |agent_class_name|
  configure_agent(agent_class_name) { { model: 'openrouter/free' } }
end
