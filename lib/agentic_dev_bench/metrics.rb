module AgenticDevBench
  # Collects and summarizes metrics from benchmark runs.
  #
  # Metrics are computed after a Harbor agent run completes. The class
  # measures:
  # * Exit code (success/failure flag)
  # * Elapsed time of the run
  # * Git diff statistics between the original commit and the final
  #   HEAD of the sandbox repository
  #
  # The workspace directory is removed after metrics collection.
  #
  # == Example
  #
  #   metrics = AgenticDevBench::Metrics.collect(
  #     workspace: workspace_path,
  #     github_repository_url: repo_url,
  #     original_commit: original_sha,
  #     exit_code: exit_code,
  #     started_at: started_time,
  #     finished_at: finished_time
  #   )
  #   # => { "exit_code" => 0, "success" => true, ... }
  #
  class Metrics
    # Collects metrics from a completed benchmark run.
    #
    # Computes the following metrics:
    # * +exit_code+ - The integer exit code from the Harbor run.
    # * +success+ - Boolean, +true+ if +exit_code+ is 0.
    # * +elapsed_seconds+ - The duration of the run in seconds (rounded to 3 decimal places).
    # * +git_diff_stat+ - The git diff --stat output showing changes made to the repository.
    #
    # After collection, the +workspace+ directory is deleted.
    #
    # The +github_repository_url+ and +original_commit+ parameters
    # are used to clone the sandbox repository and compute the diff.
    #
    # @param workspace [String] Path to the workspace directory to clean up.
    # @param run_directory [String] Path to the run directory. The temporary
    #   clone used to compute the diff is created inside it.
    # @param github_repository_url [String] The HTTPS URL of the sandbox repository.
    # @param original_commit [String] The SHA of the original commit that was pushed.
    # @param exit_code [Integer] The agent process exit status code.
    # @param started_at [Time] The timestamp when the run started.
    # @param finished_at [Time] The timestamp when the run finished.
    #
    # @return [Hash] A hash containing the collected metrics.
    def self.collect(workspace:, run_directory:, github_repository_url:, original_commit:, exit_code:, started_at:, finished_at:)
      Debug.debug("Collecting metrics for #{github_repository_url} @ #{original_commit}")
      diff = compute_git_diff(github_repository_url: github_repository_url, original_commit: original_commit, run_directory: run_directory)
      Debug.debug("Diff stat bytes=#{diff.bytesize}; cleaning workspace #{workspace}")
      FileUtils.rm_rf(workspace)
      Debug.debug('Workspace cleaned')

      {
        'exit_code' => exit_code,
        'success' => exit_code.zero?,
        'elapsed_seconds' => (finished_at - started_at).round(3),
        'git_diff_stat' => diff.strip
      }
    end

    private

    # Computes the git diff statistics for the sandbox repository.
    #
    # Clones the repository into a temporary directory, checks out the
    # original commit, and runs +git diff --stat+ against HEAD to show
    # all changes made by the agent.
    #
    # @param github_repository_url [String] The HTTPS URL of the sandbox repository.
    #   The +GITHUB_TOKEN+ environment variable must be set to allow authenticated cloning.
    # @param original_commit [String] The SHA of the original commit.
    # @param run_directory [String] Path to the run directory. The temporary
    #   clone is created inside it (and kept there when debugging).
    #
    # @return [String] The diff stat output, or an empty string if the
    #   clone or checkout fails.
    def self.compute_git_diff(github_repository_url:, original_commit:, run_directory:)
      # Clone the GitHub sandbox repository into a temporary directory inside the run directory
      temp_dir = Dir.mktmpdir('agentic-dev-bench-git', run_directory)
      begin
        Debug.debug("Cloning sandbox for diff into #{temp_dir} (URL redacted)")
        github_url = github_repository_url.gsub('https://', 'https://x-access-token:' + ENV.fetch('GITHUB_TOKEN') + '@')

        # Clone the repository (git's own trace goes to stderr when --debug)
        _stdout, stderr, status = Debug.debug_exec('git', 'clone', '--quiet', github_url, temp_dir)
        unless status.success?
          warn "git clone failed: #{Debug.redact(stderr)}"
          return ''
        end
        Debug.debug('Sandbox clone for diff succeeded')

        # Checkout the original commit and compute the diff against HEAD
        Dir.chdir(temp_dir) do
          Debug.debug("Checking out original commit #{original_commit} for diff")
          return '' unless Debug.debug_system('git', 'checkout', '--quiet', original_commit)

          Debug.debug("Computing git diff --stat #{original_commit}..HEAD")
          stdout, stderr, _status = Debug.debug_exec('git', 'diff', '--stat', original_commit, 'HEAD')
          return "#{stdout}#{stderr}".strip
        end
      ensure
        # Clean up the temporary directory, unless debugging (keep it for inspection)
        if Debug.enabled?
          Debug.debug("Keeping diff temp dir #{temp_dir}")
        else
          Debug.debug("Removing diff temp dir #{temp_dir}")
          FileUtils.rm_rf(temp_dir)
        end
      end
    end
  end
end
