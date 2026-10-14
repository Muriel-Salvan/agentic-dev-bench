# X-Aeon Agents configuration for the Harbor task container.
#
# Rendered from templates/harbor_task/environment/ into the Docker build
# context by HarborRunner#write_task_files (same as Dockerfile and
# entrypoint.sh) and baked into the image at /etc/x_aeon_agents.rb, with
# X_AEON_AGENTS_CONFIG pointing at it (see Dockerfile).
#
# Keep the agent's session state OUT of /workspace: task.toml declares the
# whole /workspace as an artifact copied into the separate verifier, and a
# sessions/... tree inside it breaks `docker compose cp` (Windows MAX_PATH /
# transient files). /tmp is world-writable for the non-root agent user and
# ephemeral per container, which is fine -- the verifier grades the repo,
# not the agent's resume state.
data_dir '/workspace/xaa'
