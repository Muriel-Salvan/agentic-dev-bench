require 'octokit'
require 'uri'
require 'cgi'

module AgenticDevBench
  # Manages the creation and destruction of ephemeral GitHub repositories
  # to serve as sandboxed environments for benchmark runs.
  #
  # GitHubSandbox clones a source repository at a specific commit into a
  # new private repository owned by the benchmark user, and creates the
  # corresponding GitHub issue with the requirements.
  #
  # == Environment Variables
  #
  # The following environment variables must be set:
  # * +GITHUB_TOKEN+ - A GitHub personal access token with repository
  #   creation and deletion permissions for the configured owner.
  # * The value of +scenario.sandbox['owner_env']+ - the environment
  #   variable name that resolves to the GitHub owner (user/org) name.
  #
  # == Example
  #
  #   sandbox = AgenticDevBench::GitHubSandbox.new(
  #     scenario: scenario,
  #     run_id: run_id
  #   )
  #   info = sandbox.provision!
  #   # => { repository: "...", repository_url: "...", issue_number: 1, ... }
  #   sandbox.destroy!  # clean up the repository
  #
  class GitHubSandbox
    # @return [String] The unique identifier of the current run.
    attr_reader :run_id

    # Initializes a new GitHubSandbox.
    #
    # Loads the GitHub owner from the environment (via +scenario.sandbox['owner_env'])
    # and sets up the Octokit client with the provided token.
    #
    # @param scenario [AgenticDevBench::Scenario] The scenario definition.
    # @param run_id [String] A unique identifier for the current benchmark run.
    def initialize(scenario:, run_id:)
      @scenario = scenario
      @run_id = run_id
      @owner = ENV.fetch(scenario.sandbox.fetch('owner_env'))
      @token = ENV.fetch('GITHUB_TOKEN')
      @client = Octokit::Client.new(access_token: @token)
      @name = "#{scenario.sandbox.fetch('name_prefix')}-#{scenario.id}-#{run_id}"
    end

    # Provisions an ephemeral GitHub sandbox repository for the benchmark run.
    #
    # This method performs the following steps:
    # 1. Clones the source repository at the specified commit into a temporary directory.
    # 2. Creates a new private repository with a generated name.
    # 3. Pushes the original commit to the new repository (located at +refs/heads/main+).
    # 4. Creates a GitHub issue with the scenario's requirements in the new repository.
    #
    # @return [Hash] A hash containing:
    #   * +repository+ [String] The full name of the created repository (owner/repo).
    #   * +repository_url+ [String] The HTML URL of the created repository.
    #   * +issue_number+ [Integer] The number of the created GitHub issue.
    #   * +issue_url+ [String] The HTML URL of the created issue.
    #   * +original_commit+ [String] The SHA of the commit pushed to the new repository.
    #
    # @raise [RuntimeError] If the source repository or commit contains placeholder
    #   text ('YOUR_'), indicating the scenario file was not updated.
    # @raise [RuntimeError] If git clone, checkout, remote setup, or push fails.
    # @raise [Octokit::Error] If GitHub API operations fail.
    def provision!
      source = @scenario.source.fetch('repository')
      commit = @scenario.source.fetch('commit')
      raise 'Replace the placeholder source repository in the scenario' if source.include?('YOUR_')
      raise 'Replace the placeholder source commit in the scenario' if commit.include?('YOUR_')

      repo = @client.create_repository(
        @name,
        description: "Ephemeral sandbox for agentic-dev-bench run #{@run_id}",
        private: true,
        auto_init: false
      )

      original_commit = nil
      Dir.mktmpdir('agentic-dev-bench-source') do |dir|
        original_commit = dir
        system('git', 'clone', '--quiet', "https://github.com/#{source}.git", dir) or raise 'git clone failed'
        Dir.chdir(dir) do
          system('git', 'checkout', '--quiet', commit) or raise 'git checkout failed'
          system('git', 'remote', 'set-url', 'origin', push_url(repo.clone_url)) or raise 'git remote setup failed'
          system('git', 'push', '--quiet', 'origin', 'HEAD:refs/heads/main') or raise 'git push failed'
          original_commit = `git rev-parse HEAD`.strip
        end
      end

      issue = @client.create_issue("#{@owner}/#{@name}", @scenario.issue.fetch('title'), @scenario.issue.fetch('body'))
      {
        'repository' => repo.full_name,
        'repository_url' => repo.html_url,
        'issue_number' => issue.number,
        'issue_url' => issue.html_url,
        'original_commit' => original_commit
      }
    end

    # Converts a GitHub repository clone URL to an authenticated URL.
    #
    # Injects the GitHub token into the URL to allow authenticated git operations
    # (e.g., pushing code) via HTTPS.
    #
    # @param url [String] The clone URL (e.g. https://github.com/owner/repo.git).
    #
    # @return [String] The authenticated URL with the token embedded:
    #   e.g. https://x-access-token:TOKEN@github.com/owner/repo.git
    #
    # @note The token is URL-encoded if it contains special characters.
    def push_url(url)
      uri = URI(url)
      uri.user = 'x-access-token'
      uri.password = CGI.escape(@token)
      uri.to_s
    end

    # Destroys the sandbox repository on GitHub.
    #
    # @return [nil] Always returns +nil+. If the repository has already
    #   been deleted (HTTP 404), this method silently swallows the error
    #   and returns +nil+.
    #
    # @raise [Octokit::NotFound] Never raised; always rescues +Octokit::NotFound+.
    def destroy!
      @client.delete_repository("#{@owner}/#{@name}")
    end

  end
end
