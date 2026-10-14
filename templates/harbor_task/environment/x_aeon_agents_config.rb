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
