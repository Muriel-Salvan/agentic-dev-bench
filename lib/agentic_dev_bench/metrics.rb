module AgenticDevBench
  # Collects and summarizes metrics from benchmark runs.
  #
  # Metrics are computed after a Harbor agent run completes. The class
  # measures:
  # * Exit code (success/failure flag)
  # * Elapsed time of the run
  # * Verifier outcome: the reward grade and pass/fail verdict read from
  #   Harbor's per-trial result, plus any exception that aborted grading
  # * Pushed feature branch(es) vs the sandbox base, with per-branch
  #   commit counts, file lists, and diff --stat summaries
  #
  # Note the deliberate separation between +success+ and +verifier_passed+:
  # +success+ only reflects whether the `harbor run` CLI process exited 0
  # (Harbor treats orchestration as successful even when the trial inside it
  # errors), whereas +verifier_passed+ reflects the actual grade produced by
  # tests/test.sh. Use +verifier_passed+ to judge the benchmark outcome.
  #
  # == Example
  #
  #   metrics, patch = AgenticDevBench::Metrics.collect(
  #     run_directory: run_directory,
  #     github_repository_url: repo_url,
  #     original_commit: original_sha,
  #     exit_code: exit_code,
  #     started_at: started_time,
  #     finished_at: finished_time
  #   )
  #   # => [{ "exit_code" => 0, "success" => true,
  #   #       "verifier_reward" => 1.0, "verifier_passed" => true, ... },
  #   #     "...patch..."]
  #
  class Metrics
    # Base branch of every sandbox repository (see GitHubSandbox#provision!,
    # which pushes the pinned commit to refs/heads/main).
    BASE_BRANCH = 'main'

    # Collects metrics from a completed benchmark run.
    #
    # Computes the following metrics:
    # * +exit_code+ - The integer exit code from the Harbor run.
    # * +success+ - Boolean, +true+ if +exit_code+ is 0. This reflects the
    #   `harbor run` CLI process only, NOT the verifier's verdict (Harbor
    #   exits 0 even when a trial errors). Prefer +verifier_passed+ to judge
    #   the benchmark outcome.
    # * +verifier_reward+ - The verifier's reward grade (a Float, e.g. 0.0 or
    #   1.0) read from Harbor's per-trial result.json, or +nil+ when no grade
    #   could be found.
    # * +verifier_passed+ - Boolean, +true+ only when +verifier_reward+ is a
    #   number >= 1.0. Distinct from +success+: it captures the actual grade
    #   produced by tests/test.sh, including failures that still left the CLI
    #   exit code at 0.
    # * +verifier_exception+ - The exception type that aborted the run (e.g.
    #   +NonZeroAgentExitCodeError+, +RewardFileNotFoundError+), or +nil+ when
    #   the trial completed without an exception.
    # * +elapsed_seconds+ - The duration of the run in seconds (rounded to 3 decimal places).
    # * +feature_branch+ - Name of the pushed feature branch (empty when none).
    # * +feature_branches+ - All pushed branches ahead of the base (comma-separated).
    # * +commits_ahead+ - Number of commits on the feature branch beyond the base.
    # * +files_changed+ - Number of files changed on the feature branch vs the base.
    # * +git_diff_stat+ - The git diff --stat output for the pushed branch(es).
    #
    # The +github_repository_url+ and +original_commit+ parameters
    # are used to clone the sandbox repository and compute the diff.
    #
    # @param run_directory [String] Path to the run directory. The temporary
    #   clone used to compute the diff is created inside it.
    # @param github_repository_url [String] The HTTPS URL of the sandbox repository.
    # @param original_commit [String] The SHA of the original commit that was pushed.
    # @param exit_code [Integer] The agent process exit status code.
    # @param started_at [Time] The timestamp when the run started.
    # @param finished_at [Time] The timestamp when the run finished.
    #
    # @return [Array<Hash, String>] A 2-element array:
    #   * [0] [Hash] The collected metrics (YAML-safe scalars only).
    #   * [1] [String] The full unified diff (empty when no branch was pushed).
    def self.collect(run_directory:, github_repository_url:, original_commit:, exit_code:, started_at:, finished_at:)
      Debug.debug("Collecting metrics for #{github_repository_url} @ #{original_commit}")
      verifier = read_verifier_result(run_directory: run_directory)
      Debug.debug("Verifier result: reward=#{verifier[:reward].inspect} passed=#{verifier[:passed]} exception=#{verifier[:exception].inspect}")
      diff_info = compute_git_diff(github_repository_url: github_repository_url, original_commit: original_commit, run_directory: run_directory)
      Debug.debug("Diff stat bytes=#{diff_info[:stat].bytesize} patch bytes=#{diff_info[:patch].bytesize}")

      metrics = {
        'exit_code' => exit_code,
        'success' => exit_code.zero?,
        'verifier_reward' => verifier[:reward],
        'verifier_passed' => verifier[:passed],
        'verifier_exception' => verifier[:exception],
        'elapsed_seconds' => (finished_at - started_at).round(3),
        'feature_branch' => diff_info[:primary_branch],
        'feature_branches' => diff_info[:branches].join(', '),
        'commits_ahead' => diff_info[:commits_ahead],
        'files_changed' => diff_info[:files_changed],
        'git_diff_stat' => diff_info[:stat].strip
      }
      [metrics, diff_info[:patch]]
    end

    private

    # Reads the verifier verdict from Harbor's per-trial result.json.
    #
    # With +environment_mode = "separate"+ (see task.toml), Harbor runs
    # tests/test.sh in its own container and records the grade in
    # <run_directory>/jobs/<timestamp>/task__*/result.json under
    # +verifier_result.rewards.reward+, plus any +exception_info.exception_type+
    # that aborted the trial (e.g. NonZeroAgentExitCodeError, RewardFileNotFoundError).
    #
    # When several task__*/result.json files exist (Harbor retries), the trial
    # with the latest +finished_at+ wins; ties fall back to file mtime.
    #
    # @param run_directory [String] Path to the run_directory directory (contains jobs/).
    #
    # @return [Hash] A hash with:
    #   * +:reward+ [Float, nil] The verifier reward grade, or nil when absent.
    #   * +:passed+ [Boolean] True only when the reward is a number >= 1.0.
    #   * +:exception+ [String, nil] The exception type, or nil when none.
    def self.read_verifier_result(run_directory:)
      absent = { reward: nil, passed: false, exception: nil }
      return absent.merge(exception: 'ResultFileNotFound') if run_directory.nil? || run_directory.to_s.empty?

      pattern = File.join(run_directory, 'jobs', '**', 'task__*', 'result.json')
      files = Dir.glob(pattern).select { |path| File.file?(path) }
      if files.empty?
        Debug.debug("No Harbor trial result.json found under #{File.join(run_directory, 'jobs')}")
        return absent.merge(exception: 'ResultFileNotFound')
      end

      result_file = files.max_by do |path|
        data = safe_parse_json(path)
        finished = data && data['finished_at']
        finished.is_a?(String) && !finished.empty? ? finished : File.mtime(path).iso8601
      end
      Debug.debug("Reading verifier result from #{result_file}")

      data = safe_parse_json(result_file)
      return absent.merge(exception: 'ResultFileUnparseable') if data.nil?

      reward = data.dig('verifier_result', 'rewards', 'reward')
      reward = reward.to_f if reward.is_a?(Numeric)
      exception = data.dig('exception_info', 'exception_type')
      exception = nil unless exception.is_a?(String) && !exception.empty?

      {
        reward: reward,
        passed: reward.is_a?(Numeric) && reward >= 1.0,
        exception: exception
      }
    end

    # Parses a JSON file, returning nil (with a debug log) on any failure.
    #
    # Never raises: a missing, unreadable, or malformed result.json must not
    # abort metrics collection.
    #
    # @param path [String] Path to the JSON file to parse.
    #
    # @return [Hash, nil] The parsed object, or nil when it could not be read.
    def self.safe_parse_json(path)
      JSON.parse(File.read(path, encoding: 'UTF-8'))
    rescue StandardError => e
      Debug.debug("Could not parse JSON at #{path}: #{e.class}: #{e.message}")
      nil
    end

    # Computes the git diff for branches the agent pushed to the sandbox.
    #
    # The agent is instructed to work on a new feature branch (see the
    # Harbor instruction.md), and the verifier grades
    # <tt>origin/main..origin/&lt;feature&gt;</tt>. So instead of diffing
    # the base commit against a detached HEAD (which is always empty),
    # this clones the sandbox, refreshes all remote branches, and diffs
    # each pushed branch ahead of the base commit.
    #
    # Git's own trace output (GIT_TRACE) is suppressed for these calls so
    # debug mode cannot leak into the metric; stderr is only debug-logged
    # (redacted), never embedded in the returned strings.
    #
    # @param github_repository_url [String] The HTTPS URL of the sandbox repository.
    #   The +GITHUB_TOKEN+ environment variable must be set to allow authenticated cloning.
    # @param original_commit [String] The SHA of the original commit.
    # @param run_directory [String] Path to the run directory. The temporary
    #   clone is created inside it (and kept there when debugging).
    #
    # @return [Hash] A hash with +:branches+, +:primary_branch+,
    #   +:commits_ahead+, +:files_changed+, +:stat+, and +:patch+.
    def self.compute_git_diff(github_repository_url:, original_commit:, run_directory:)
      empty = { branches: [], primary_branch: '', commits_ahead: 0, files_changed: 0, stat: '', patch: '' }
      # Clone the GitHub sandbox repository into a temporary directory inside the run directory
      Debug.with_debug_dir(File.join(run_directory, 'git-diff'), 'Github result clone') do |temp_dir|
        Debug.debug("Cloning sandbox for diff into #{temp_dir} (URL redacted)")
        github_url = github_repository_url.gsub('https://', 'https://x-access-token:' + ENV.fetch('GITHUB_TOKEN') + '@')

        # Clone the repository (git's own trace suppressed: stderr must stay clean)
        _stdout, stderr, status = Debug.debug_exec('git', 'clone', '--quiet', github_url, temp_dir, git_trace: false)
        unless status.success?
          warn "git clone failed: #{Debug.redact(stderr)}"
          return empty
        end
        Debug.debug('Sandbox clone for diff succeeded')

        Dir.chdir(temp_dir) do
          Debug.debug('Refreshing remote branches for diff')
          _fetch_stdout, fetch_stderr, _fetch_status = Debug.debug_exec(
            'git', 'fetch', '--prune', 'origin', '+refs/heads/*:refs/remotes/origin/*', git_trace: false
          )
          Debug.debug("Fetch stderr: #{Debug.redact(fetch_stderr.strip)}") unless fetch_stderr.strip.empty?

          branches = pushed_feature_branches(original_commit: original_commit)
          branches = ['main'] if branches.empty? && main_ahead?(original_commit: original_commit)
          if branches.empty?
            Debug.debug('No pushed feature branch found; diff is empty')
            return empty
          end
          Debug.debug("Pushed feature branches: #{branches.inspect}")

          build_branch_diffs(branches: branches, original_commit: original_commit)
        end
      end
    end

    # Lists remote branches carrying at least one commit beyond the base.
    #
    # Mirrors the verifier logic in tests/test.sh: enumerate
    # <tt>refs/remotes/origin</tt> (excluding main/HEAD), keep branches
    # with <tt>rev-list --count base..branch >= 1</tt>.
    #
    # @param original_commit [String] The base SHA pushed at provisioning time.
    #
    # @return [Array<String>] Sorted branch names ahead of the base.
    def self.pushed_feature_branches(original_commit:)
      stdout, stderr, _status = Debug.debug_exec(
        'git', 'for-each-ref', '--format=%(refname:strip=3)', 'refs/remotes/origin', git_trace: false
      )
      Debug.debug("for-each-ref stderr: #{Debug.redact(stderr.strip)}") unless stderr.strip.empty?
      candidates = stdout.lines.map(&:strip).reject(&:empty?) - [BASE_BRANCH, 'HEAD']
      candidates.select do |branch|
        count_stdout, count_stderr, _count_status = Debug.debug_exec(
          'git', 'rev-list', '--count', "#{original_commit}..origin/#{branch}", git_trace: false
        )
        unless count_stderr.strip.empty?
          Debug.debug("rev-list stderr (#{branch}): #{Debug.redact(count_stderr.strip)}")
        end
        count_stdout.strip.to_i >= 1
      end.sort
    end

    # Reports whether main itself advanced beyond the base commit.
    #
    # The verifier demands a separate feature branch, so a direct push to
    # main is still a failure — but surfacing its diff beats an empty
    # metric when diagnosing such runs.
    #
    # @param original_commit [String] The base SHA pushed at provisioning time.
    #
    # @return [Boolean] True when origin/main is ahead of the base.
    def self.main_ahead?(original_commit:)
      count_stdout, count_stderr, _status = Debug.debug_exec(
        'git', 'rev-list', '--count', "#{original_commit}..origin/#{BASE_BRANCH}", git_trace: false
      )
      unless count_stderr.strip.empty?
        Debug.debug("rev-list stderr (#{BASE_BRANCH}): #{Debug.redact(count_stderr.strip)}")
      end
      count_stdout.strip.to_i >= 1
    end

    # Builds per-branch diff --stat sections plus a combined unified patch.
    #
    # @param branches [Array<String>] Pushed branches ahead of the base (sorted).
    # @param original_commit [String] The base SHA pushed at provisioning time.
    #
    # @return [Hash] Same shape as {.compute_git_diff} (never the empty sentinel).
    def self.build_branch_diffs(branches:, original_commit:)
      stat_sections = []
      patches = []
      total_files = 0
      primary_ahead = 0

      branches.each_with_index do |branch, index|
        Debug.debug("Computing git diff --stat #{original_commit}..origin/#{branch}")
        stat_stdout, stat_stderr, _stat_status = Debug.debug_exec(
          'git', 'diff', '--stat', original_commit, "origin/#{branch}", git_trace: false
        )
        unless stat_stderr.strip.empty?
          Debug.debug("diff --stat stderr (#{branch}): #{Debug.redact(stat_stderr.strip)}")
        end

        count_stdout, _count_stderr, _count_status = Debug.debug_exec(
          'git', 'rev-list', '--count', "#{original_commit}..origin/#{branch}", git_trace: false
        )
        ahead = count_stdout.strip.to_i
        primary_ahead = ahead if index.zero?

        files_stdout, _files_stderr, _files_status = Debug.debug_exec(
          'git', 'diff', '--name-only', original_commit, "origin/#{branch}", git_trace: false
        )
        file_count = files_stdout.lines.map(&:strip).reject(&:empty?).length
        total_files = file_count if index.zero?

        stat_sections << "Branch: origin/#{branch} (#{ahead} commit(s) ahead)\n#{stat_stdout.strip}".strip

        Debug.debug("Computing full diff #{original_commit}..origin/#{branch}")
        patch_stdout, patch_stderr, _patch_status = Debug.debug_exec(
          'git', 'diff', original_commit, "origin/#{branch}", git_trace: false
        )
        unless patch_stderr.strip.empty?
          Debug.debug("diff stderr (#{branch}): #{Debug.redact(patch_stderr.strip)}")
        end
        patches << patch_stdout unless patch_stdout.strip.empty?
      end

      {
        branches: branches,
        primary_branch: branches.first,
        commits_ahead: primary_ahead,
        files_changed: total_files,
        stat: stat_sections.join("\n\n"),
        patch: patches.join("\n")
      }
    end
  end
end
