module AgenticDevBench
  # Runs benchmark scenarios in a Harbor task environment.
  #
  # HarborRunner prepares a Harbor-compatible task directory structure (instruction,
  # task configuration, Dockerfile environment, and verification tests) and executes
  # the Harbor CLI to have an AI agent complete the task. It captures the agent's
  # output and exit status for metrics collection.
  #
  # == Harbor Task Directory Structure (Harbor 0.24.0)
  #
  #   task_dir/
  #     instruction.md     # The prompt for the AI agent
  #     task.toml          # Harbor task configuration
  #     environment/
  #       Dockerfile       # Container image definition
  #     tests/
  #       test.sh          # Verification script run after the agent finishes
  #
  # == Example
  #
  #   runner = AgenticDevBench::HarborRunner.new(
  #     scenario: scenario,
  #     sandbox: sandbox_info,
  #     workspace: workspace_path
  #   )
  #   result = runner.run!
  #   # => #<struct AgenticDevBench::HarborRunner::Result
  #   #      exit_code=0, stdout="...", stderr="...">
  #
  class HarborRunner
    # Result of a Harbor run, capturing the agent's execution status.
    #
    # @!attribute [rw] exit_code
    #   @return [Integer] The agent process exit status code.
    # @!attribute [rw] stdout
    #   @return [String] The standard output captured from the Harbor run.
    # @!attribute [rw] stderr
    #   @return [String] The standard error captured from the Harbor run.
    Result = Data.define(:exit_code, :stdout, :stderr)

    # @return [AgenticDevBench::Scenario] The benchmark scenario being executed.
    attr_reader :scenario

    # @return [Hash] The sandbox repository information.
    attr_reader :sandbox

    # @return [String] The path to the workspace directory.
    attr_reader :workspace

    # Initializes a new HarborRunner.
    #
    # @param scenario [AgenticDevBench::Scenario] The benchmark scenario to run.
    # @param sandbox [Hash] The sandbox repository information (as returned by
    #   GitHubSandbox#provision!).
    # @param workspace [String] The path to the workspace directory where the
    #   task files will be written and the Harbor run will be executed.
    def initialize(scenario:, sandbox:, workspace:)
      @scenario = scenario
      @sandbox = sandbox
      @workspace = workspace
    end

    # Runs the agent in the Harbor environment.
    #
    # Prepares the task directory structure and executes the Harbor CLI with
    # the agent and model specified in the scenario. Captures all output and
    # returns a Result object.
    #
    # @return [HarborRunner::Result] A Data object with:
    #   * +exit_code+ [Integer] The Harbor process exit status.
    #   * +stdout+ [String] The captured stdout.
    #   * +stderr+ [String] The captured stderr.
    #
    # @raise [SystemCallError] If the Harbor CLI command fails to execute.
    def run!
      task_dir = File.join(@workspace, 'task')
      FileUtils.mkdir_p(task_dir)

      # Harbor 0.24.0 task directory structure:
      #   task_dir/
      #     instruction.md
      #     task.toml
      #     environment/
      #       Dockerfile
      #     tests/
      #       test.sh
      write_instruction_file(task_dir)
      write_task_toml(task_dir)
      write_environment_dockerfile(task_dir)
      write_tests(test_dir = File.join(task_dir, 'tests'))
      FileUtils.mkdir_p(test_dir)

      # Harbor 0.24.0 CLI: harbor run -p <task_directory> -a <agent> -m <model>
      # The old `--task <file>` syntax is no longer supported in Harbor 0.24.0
      agent_name = @scenario.agent.fetch('name')
      model = @scenario.agent.fetch('model')
      argv = ['harbor', 'run', '-p', task_dir, '-a', agent_name, '-m', model]
      stdout, stderr, status = Open3.capture3(*argv)
      Result.new(status.exitstatus, stdout, stderr)
    end

    private

    # Writes the instruction file describing the benchmark task to the agent.
    #
    # @param task_dir [String] The directory where the instruction file will be written.
    def write_instruction_file(task_dir)
      instruction = <<~TXT
        Work on the GitHub repository #{@sandbox.fetch('repository_url')}.
        An issue containing the benchmark requirements has already been created.
        Implement the requirements, add appropriate tests, and create a pull request when appropriate.
      TXT
      File.write(File.join(task_dir, 'instruction.md'), instruction)
    end

    # Writes the Harbor task configuration file.
    #
    # Configures the task for the Ruby language with an unknown framework
    # and a Docker-based environment.
    #
    # @param task_dir [String] The directory where task.toml will be written.
    def write_task_toml(task_dir)
      task_toml = <<~TOML
        # Harbor task configuration
        language = "ruby"
        framework = "unknown"
        environment_type = "docker"
      TOML
      File.write(File.join(task_dir, 'task.toml'), task_toml)
    end

    # Writes the Dockerfile for the task environment.
    #
    # The Dockerfile sets up a Ruby 3.4 environment with git and Docker
    # pre-installed, and sets the working directory to /workspace.
    #
    # @param task_dir [String] The parent directory where environment/ will be created.
    def write_environment_dockerfile(task_dir)
      dockerfile = <<~DOCKERFILE
        # Base image for the Harbor task environment
        FROM ruby:3.4-bookworm

        # Install required system packages
        RUN apt-get update -qq && apt-get install -y --no-install-recommends \
          git \
          docker.io \
          && rm -rf /var/lib/apt/lists/*

        # Set the working directory inside the container
        WORKDIR /workspace
      DOCKERFILE
      env_dir = File.join(task_dir, 'environment')
      FileUtils.mkdir_p(env_dir)
      File.write(File.join(env_dir, 'Dockerfile'), dockerfile)
    end

    # Writes the verification test script that runs after the agent finishes.
    #
    # The script verifies that a greeting helper was implemented correctly:
    # it requires './lib/greeting', calls the +greeting+ function, and
    # checks the output is exactly "Hello, world!".
    #
    # @param test_dir [String] The directory where test.sh will be written.
    def write_tests(test_dir)
      # The agent should implement a greeting helper that returns "Hello, world!"
      # and add automated tests for it. The test script runs after the agent
      # finishes and verifies the implementation.
      test_script = <<~BASH
        #!/bin/bash
        set -e

        # Verify that the greeting helper exists and returns the expected value.
        greeting=$(ruby -e "require './lib/greeting'; puts greeting")

        if [ "$greeting" != "Hello, world!" ]; then
          echo "FAIL: greeting did not return 'Hello, world!', got: $greeting"
          exit 1
        fi

        echo "PASS: greeting helper works correctly"
      BASH
      FileUtils.mkdir_p(test_dir)
      File.write(File.join(test_dir, 'test.sh'), test_script)
      File.chmod(0o755, File.join(test_dir, 'test.sh'))
    end
  end
end
