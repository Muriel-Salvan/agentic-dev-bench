require 'open3'

module AgenticDevBench
  # Central debug-logging helper.
  #
  # The --debug flag is set once via Debug.set_debug!() (called from the CLI)
  # and read via Debug.enabled?. All logging funnels through this
  # module so output has a consistent timestamped format.
  #
  # Subprocess helpers redact embedded credentials (e.g. x-access-token
  # URLs) before logging, and automatically enable each tool's own
  # verbose mode when debug is on:
  # * git: GIT_TRACE=1 + GIT_CURL_VERBOSE=1
  # * docker (via harbor): DOCKER_DEBUG=1 + BUILDKIT_PROGRESS=plain
  # * harbor: `--debug` flag + PYTHONUNBUFFERED=1, plus logged command +
  #   exit status + output tails (live-mirrored via capture3_streaming)
  module Debug
    # Matches embedded credentials in URLs (tokens, passwords).
    REDACTED = '[REDACTED]'.freeze

    class << self
      # Enable or disable debug logging.
      #
      # @param value [Boolean] True to enable debug logging.
      def set_debug!(value)
        @debug = !!value
      end

      # Return whether debug logging is enabled.
      #
      # @return [Boolean]
      def enabled?
        !!@debug
      end

      # Log an info-level debug message with a UTC timestamp.
      #
      # @param msg [String] The message to log.
      def debug(msg)
        return unless enabled?

        puts "[DEBUG #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}] #{msg}"
      end

      # Redact credentials from a string before logging.
      #
      # Strips `x-access-token:...@`, `:password@`, and
      # `?token=...` style secrets, plus bare token values for known
      # secret env vars and `KEY=secret` pairs.
      #
      # @param str [String] Raw string that may contain secrets.
      # @param redactions [Array<String>] Extra secret plaintext values to
      #   mask literally (longest first). The `GITHUB_TOKEN`, `GH_TOKEN`,
      #   and `AGENT_GITHUB_TOKEN` env values are always included
      #   automatically when present.
      # @return [String] Redacted string safe to log.
      def redact(str, redactions = [])
        s = str.to_s.dup
        secrets = Array(redactions).map(&:to_s).reject(&:empty?)
        secrets |= [ENV['GITHUB_TOKEN'], ENV['GH_TOKEN'], ENV['AGENT_GITHUB_TOKEN']].compact.reject(&:empty?)
        secrets.sort_by(&:length).reverse.each do |secret|
          s = s.gsub(secret, REDACTED)
        end
        s.gsub!(%r{(x-access-token:)[^@\s'"]+@}i, '\1' + REDACTED + '@')
        s.gsub!(%r{(://)[^/\s:'"@]+:[^/\s:'"@]+@}i, '\1' + REDACTED + '@')
        s.gsub!(/([?&]token=)[^&\s'"]+/i, '\1' + REDACTED)
        s.gsub!(/GITHUB_TOKEN["']?\s*(?:=>|:|=)\s*["']?[^"'\s,}]+/i, "GITHUB_TOKEN=[REDACTED]")
        s.gsub!(/GH_TOKEN["']?\s*(?:=>|:|=)\s*["']?[^"'\s,}]+/i, "GH_TOKEN=[REDACTED]")
        s.gsub!(/AGENT_GITHUB_TOKEN["']?\s*(?:=>|:|=)\s*["']?[^"'\s,}]+/i, "AGENT_GITHUB_TOKEN=[REDACTED]")
        s
      end

      # Env vars that enable git's own trace output when debugging.
      #
      # @return [Hash] Extra env for git child processes.
      def git_debug_env
        return {} unless enabled?

        { 'GIT_TRACE' => '1', 'GIT_CURL_VERBOSE' => '1' }
      end

      # Log a debug message before running a subprocess, capturing its
      # stdout/stderr via Open3.popen3 with the same arguments.
      #
      # Accepts either `debug_exec(['git', 'status'])` or
      # `debug_exec('git', 'status')`. An optional leading Hash is treated
      # as env (merged with git trace env for git commands).
      #
      # All logging goes through {.redact} so token values passed via
      # +env+ (e.g. GITHUB_TOKEN) never appear in plain text.
      #
      # The child is always run via the Open3 block form; when {.enabled?}
      # is true each reader thread additionally mirrors its stream in real
      # time to this process's $stdout/$stderr (useful for long-running
      # commands like `harbor run`) while still capturing for the return
      # value. When disabled, output is only captured, with no extra writes.
      #
      # @param cmd [Array<String>] The command and arguments to run.
      # @param opts [Hash] Options forwarded to Open3.popen3 (Process.spawn),
      #   plus Open3.capture3-compatible :stdin_data and :binmode.
      # @return [Array<String, String, Process::Status>] stdout, stderr, status.
      def debug_exec(*cmd, **opts)
        argv = cmd.length == 1 && cmd.first.is_a?(Array) ? cmd.first.dup : cmd.dup
        env = argv.first.is_a?(Hash) ? argv.shift : {}
        # Auto-enable git tracing for git invocations.
        env = git_debug_env.merge(env) if argv.first.to_s == 'git' && enabled?
        debug("Running: #{redact(argv.inspect)}")
        debug("  env: #{redact(env.inspect)}") unless env.empty?
        stdout, stderr, status = capture3_streaming(env, argv, opts)
        if enabled?
          debug("  exit=#{status.exitstatus}")
          debug("  stdout tail: #{redact(stdout.to_s.lines.last(5)&.join.to_s.strip)}") unless stdout.to_s.empty?
          debug("  stderr tail: #{redact(stderr.to_s.lines.last(5)&.join.to_s.strip)}") unless stderr.to_s.empty?
        end
        [stdout, stderr, status]
      end

      # Log and run a command via Kernel.system, returning its boolean
      # status. Merges git trace env for git commands when debugging.
      #
      # @param cmd [Array<String>] Command and args.
      # @return [Boolean] True if the command exited successfully.
      def debug_system(*cmd)
        argv = cmd.length == 1 && cmd.first.is_a?(Array) ? cmd.first.dup : cmd.dup
        env = argv.first.is_a?(Hash) ? argv.shift : {}
        env = git_debug_env.merge(env) if argv.first.to_s == 'git' && enabled?
        debug("Running (system): #{redact(argv.inspect)}")
        system(env, *argv, exception: true)
      end

      private

      # Like Open3.capture3 but built on the Open3.popen3 block form, mirroring
      # child stdout/stderr to $stdout/$stderr in real time while still
      # capturing them for the return value — but only when debugging.
      #
      # Both pipes are drained concurrently in separate threads via
      # readpartial so a large burst on one stream cannot deadlock the child
      # while the other is being read. Each chunk is always appended to its
      # captured string; only when {.enabled?} is true is it also written
      # verbatim to the matching parent stream, then flushed for real-time
      # visibility. When disabled, output is only captured.
      #
      # Capture3-specific options (:stdin_data, :binmode) are handled here;
      # all remaining opts are forwarded to Open3.popen3 (Process.spawn).
      # The child's stdin is always closed (after writing :stdin_data when
      # given) so commands waiting on EOF still terminate.
      #
      # Parent-side streaming failures (closed $stdout, encoding issues) never
      # mask the child's result: the chunk stays captured and the error is
      # ignored.
      #
      # @param env [Hash] Env vars for the child process.
      # @param argv [Array<String>] Command and arguments to run.
      # @param opts [Hash] Spawn opts plus optional :stdin_data/:binmode.
      # @return [Array<String, String, Process::Status>] stdout, stderr, status.
      def capture3_streaming(env, argv, opts)
        spawn_opts = opts.dup
        stdin_data = spawn_opts.delete(:stdin_data)
        binmode = spawn_opts.delete(:binmode)
        stream = enabled?

        stdout_str = binmode ? String.new(encoding: Encoding::BINARY) : +''
        stderr_str = binmode ? String.new(encoding: Encoding::BINARY) : +''
        status = nil

        Open3.popen3(env, *argv, **spawn_opts) do |stdin, stdout_io, stderr_io, wait_thr|
          stdout_io.binmode if binmode
          stderr_io.binmode if binmode
          stdin.binmode if binmode

          out_thread = Thread.new do
            begin
              loop do
                chunk = stdout_io.readpartial(8192)
                stdout_str << chunk
                next unless stream

                begin
                  $stdout.write(chunk)
                  $stdout.flush if $stdout.respond_to?(:flush)
                rescue IOError, SystemCallError, EncodingError
                  # Still captured above; streaming must not fail the run.
                end
              end
            rescue EOFError, IOError
              # Pipe drained/closed: child exited.
            end
          end
          out_thread.report_on_exception = false

          err_thread = Thread.new do
            begin
              loop do
                chunk = stderr_io.readpartial(8192)
                stderr_str << chunk
                next unless stream

                begin
                  $stderr.write(chunk)
                  $stderr.flush if $stderr.respond_to?(:flush)
                rescue IOError, SystemCallError, EncodingError
                  # Still captured above; streaming must not fail the run.
                end
              end
            rescue EOFError, IOError
              # Pipe drained/closed: child exited.
            end
          end
          err_thread.report_on_exception = false

          begin
            stdin.write(stdin_data) unless stdin_data.nil?
          rescue IOError, SystemCallError
            # Child exited early / closed stdin; captured output still returned.
          ensure
            begin
              stdin.close
            rescue IOError
              nil
            end
          end

          status = wait_thr.value
          out_thread.join
          err_thread.join
        end

        [stdout_str, stderr_str, status]
      end
    end
  end
end
