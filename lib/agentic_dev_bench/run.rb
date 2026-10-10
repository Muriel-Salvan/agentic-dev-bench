module AgenticDevBench
  # Orchestrates a benchmark run end-to-end.
  #
  # Run prepares a uniquely-named directory, provisions a GitHub sandbox,
  # executes the scenario in Harbor, collects metrics, and saves all run
  # artifacts (sandbox config, logs, and results). The sandbox is destroyed
  # at the end of the run unless +keep: true+ is passed.
  #
  # == Run Directory Structure
  #
  # Each run creates a directory under +runs/+ with a timestamp-ID prefix
  # (e.g. +runs/20261007T120000Z-3f9a2b1c+). Inside:
  # * +sandbox.yml+ - The GitHub sandbox metadata
  # * +stdout.log+ - Standard output from the Harbor run
  # * +stderr.log+ - Standard error from the Harbor run
  # * +result.yml+ - The collected metrics
  #
  # == Example
  #
  #   run = AgenticDevBench::Run.new(scenario)
  #   run_id, metrics = run.execute!(keep: false)
  #   puts "Run: runs/#{run_id}"
  #
  class Run
    # @return [AgenticDevBench::Scenario] The scenario being executed.
    attr_reader :scenario

    # @return [String] The unique identifier of this run.
    attr_reader :id

    # @return [String] The absolute path of the run directory under +runs/+.
    attr_reader :directory

    # Initializes a new Run.
    #
    # Generates a unique run ID using the current UTC timestamp and a
    # random hex suffix. Computes the run directory path under the
    # +runs/+ folder relative to the project root.
    #
    # @param scenario [AgenticDevBench::Scenario] The scenario to execute.
    def initialize(scenario)
      @scenario = scenario
      @id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
      @directory = File.expand_path(File.join('runs', @id))
    end

    # Executes the benchmark run end-to-end.
    #
    # Performs these steps in order:
    # 1. Creates the run directory.
    # 2. Provisions a GitHub sandbox repository (via GitHubSandbox).
    # 3. Writes sandbox metadata to +sandbox.yml+.
    # 4. Creates the workspace directory.
    # 5. Runs the Harbor agent (via HarborRunner).
    # 6. Collects metrics.
    # 7. Saves stdout, stderr, and result to the run directory.
    #
    # @param keep [Boolean] When +true+, the GitHub sandbox is preserved
    #   after the run completes (useful for debugging). Default: +false+.
    #
    # @return [Array] A 2-element array:
    #   * [0] [String] The run ID.
    #   * [1] [Hash] The collected metrics.
    #
    # @raise [RuntimeError] If the GitHub repository clone fails.
    # @raise [Octokit::Error] If GitHub API operations fail.
    def execute!(keep: false)
      Debug.debug("Starting run #{@id} in directory #{@directory}")
      FileUtils.mkdir_p(@directory)

      sandbox = GitHubSandbox.new(scenario: @scenario, run: self, keep: keep)
      begin
        Debug.debug("Provisioning GitHub sandbox for #{@scenario.id}...")
        sandbox_info = sandbox.provision!
        Debug.debug("Sandbox provisioned: #{sandbox_info['repository_url']}")
        if Debug.enabled?
          File.write(File.join(@directory, 'sandbox.yml'), sandbox_info.to_yaml)
          Debug.debug("Wrote sandbox.yml")
        end

        workspace = File.join(@directory, 'workspace')
        FileUtils.mkdir_p(workspace)
        begin
          Debug.debug("Created workspace: #{workspace}")

          Debug.debug("Running Harbor agent for #{@scenario.id}...")
          started_at = Time.now
          result = HarborRunner.new(scenario: @scenario, sandbox: sandbox_info, workspace: workspace).run!
          finished_at = Time.now
          Debug.debug("Harbor run finished with exit_code=#{result.exit_code}")

          Debug.debug("Collecting metrics...")
          metrics = Metrics.collect(
            workspace: workspace,
            run_directory: @directory,
            github_repository_url: sandbox_info['repository_url'],
            original_commit: sandbox_info['original_commit'],
            exit_code: result.exit_code,
            started_at: started_at,
            finished_at: finished_at
          )
          Debug.debug("Collected metrics: #{metrics.inspect}")

          results_dir = File.join(@directory, 'results')
          FileUtils.mkdir_p(results_dir)
          File.write(File.join(results_dir, 'stdout.log'), result.stdout)
          File.write(File.join(results_dir, 'stderr.log'), result.stderr)
          File.write(File.join(results_dir, 'result.yml'), metrics.to_yaml)
          Debug.debug("Saved results to #{results_dir}")
        ensure
          if Debug.enabled?
            Debug.debug('Workspace kept for debugging')
          else
            FileUtils.rm_rf(workspace)
            Debug.debug('Workspace cleaned')
          end
        end

        [@id, metrics]
      ensure
        sandbox.destroy!
      end
    end
  end
end
