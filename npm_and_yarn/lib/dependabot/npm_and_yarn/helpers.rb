# typed: strict
# frozen_string_literal: true

require "dependabot/dependency"
require "dependabot/file_parsers"
require "dependabot/file_parsers/base"
require "dependabot/shared_helpers"
require "sorbet-runtime"

module Dependabot
  module NpmAndYarn
    module Helpers # rubocop:disable Metrics/ModuleLength
      extend T::Sig

      YARN_PATH_NOT_FOUND =
        /^.*(?<error>The "yarn-path" option has been set \(in [^)]+\), but the specified location doesn't exist)/

      # NPM Version Constants
      NPM_V10 = 10
      NPM_V8 = 8
      NPM_V6 = 6
      NPM_DEFAULT_VERSION = NPM_V10

      # PNPM Version Constants
      PNPM_V9 = 9
      PNPM_V8 = 8
      PNPM_V7 = 7
      PNPM_V6 = 6
      PNPM_DEFAULT_VERSION = PNPM_V9
      PNPM_FALLBACK_VERSION = PNPM_V6

      # BUN Version Constants
      BUN_V1 = 1
      BUN_DEFAULT_VERSION = BUN_V1

      # YARN Version Constants
      YARN_V3 = 3
      YARN_V2 = 2
      YARN_V1 = 1
      YARN_DEFAULT_VERSION = YARN_V3
      YARN_FALLBACK_VERSION = YARN_V1

      # corepack supported package managers
      SUPPORTED_COREPACK_PACKAGE_MANAGERS = %w(npm yarn pnpm).freeze

      sig { params(lockfile: T.nilable(DependencyFile)).returns(Integer) }
      def self.npm_version_numeric(lockfile)
        detected_npm_version = detect_npm_version(lockfile)

        return NPM_DEFAULT_VERSION if detected_npm_version.nil? || detected_npm_version == NPM_V6

        detected_npm_version
      end

      sig { params(lockfile: T.nilable(DependencyFile)).returns(T.nilable(Integer)) }
      def self.detect_npm_version(lockfile)
        lockfile_content = lockfile&.content

        # Return npm 10 as the default if the lockfile is missing or empty
        return NPM_DEFAULT_VERSION if lockfile_content.nil? || lockfile_content.strip.empty?

        parsed_lockfile = JSON.parse(lockfile_content)

        lockfile_version_str = parsed_lockfile["lockfileVersion"]

        return NPM_DEFAULT_VERSION if lockfile_version_str.nil? || lockfile_version_str.to_s.strip.empty?

        lockfile_version = lockfile_version_str.to_i

        # Using npm 8 as the default for lockfile_version > 2.
        return NPM_V10 if lockfile_version >= 3
        return NPM_V8 if lockfile_version >= 2

        NPM_V6 if lockfile_version >= 1
        # Return nil if can't capture
      rescue JSON::ParserError
        NPM_DEFAULT_VERSION # Fallback to npm 8 if the lockfile content cannot be parsed
      end

      private_class_method :detect_npm_version

      sig { params(yarn_lock: T.nilable(DependencyFile)).returns(Integer) }
      def self.yarn_version_numeric(yarn_lock)
        lockfile_content = yarn_lock&.content

        return YARN_DEFAULT_VERSION if lockfile_content.nil? || lockfile_content.strip.empty?

        if yarn_berry?(yarn_lock)
          YARN_DEFAULT_VERSION
        else
          YARN_FALLBACK_VERSION
        end
      end

      # Mapping from lockfile versions to PNPM versions is at
      # https://github.com/pnpm/spec/tree/274ff02de23376ad59773a9f25ecfedd03a41f64/lockfile, but simplify it for now.

      sig { params(pnpm_lock: T.nilable(DependencyFile)).returns(Integer) }
      def self.pnpm_version_numeric(pnpm_lock)
        lockfile_content = pnpm_lock&.content

        return PNPM_DEFAULT_VERSION if !lockfile_content || lockfile_content.strip.empty?

        pnpm_lockfile_version_str = pnpm_lockfile_version(pnpm_lock)

        return PNPM_FALLBACK_VERSION unless pnpm_lockfile_version_str

        pnpm_lockfile_version = pnpm_lockfile_version_str.to_f

        return PNPM_V9 if pnpm_lockfile_version >= 9.0
        return PNPM_V8 if pnpm_lockfile_version >= 6.0
        return PNPM_V7 if pnpm_lockfile_version >= 5.4

        PNPM_FALLBACK_VERSION
      end

      sig { params(_bun_lock: T.nilable(DependencyFile)).returns(Integer) }
      def self.bun_version_numeric(_bun_lock)
        BUN_DEFAULT_VERSION
      end

      sig { params(key: String, default_value: String).returns(T.untyped) }
      def self.fetch_yarnrc_yml_value(key, default_value)
        if File.exist?(".yarnrc.yml") && (yarnrc = YAML.load_file(".yarnrc.yml"))
          yarnrc.fetch(key, default_value)
        else
          default_value
        end
      end

      sig { params(package_lock: T.nilable(DependencyFile)).returns(T::Boolean) }
      def self.parse_npm8?(package_lock)
        return true unless package_lock&.content

        detected_npm = detect_npm_version(package_lock)
        # For conversion reading properly from npm 6 lockfile we need to check if detected version is npm 6
        detected_npm.nil? || detected_npm != NPM_V6
      end

      sig { params(yarn_lock: T.nilable(DependencyFile)).returns(T::Boolean) }
      def self.yarn_berry?(yarn_lock)
        return false if yarn_lock.nil? || yarn_lock.content.nil?

        yaml = YAML.safe_load(T.must(yarn_lock.content))
        yaml.key?("__metadata")
      rescue StandardError
        false
      end

      sig { returns(T.any(Integer, T.noreturn)) }
      def self.yarn_major_version
        retries = 0
        output = run_single_yarn_command("--version")
        Version.new(output).major
      rescue Dependabot::SharedHelpers::HelperSubprocessFailed => e
        # Should never happen, can probably be removed once this settles
        raise "Failed to replace ENV, not sure why" if T.must(retries).positive?

        message = e.message

        missing_env_var_regex = %r{Environment variable not found \((?:[^)]+)\) in #{Dir.pwd}/(?<path>\S+)}

        if message.match?(missing_env_var_regex)
          match = T.must(message.match(missing_env_var_regex))
          path = T.must(match.named_captures["path"])

          File.write(path, File.read(path).gsub(/\$\{[^}-]+\}/, ""))
          retries = T.must(retries) + 1

          retry
        end

        handle_subprocess_failure(e)
      end

      sig { params(error: StandardError).returns(T.noreturn) }
      def self.handle_subprocess_failure(error)
        message = error.message
        if YARN_PATH_NOT_FOUND.match?(message)
          error = T.must(T.must(YARN_PATH_NOT_FOUND.match(message))[:error]).sub(Dir.pwd, ".")
          raise MisconfiguredTooling.new("Yarn", error)
        end

        if message.include?("Internal Error") && message.include?(".yarnrc.yml")
          raise MisconfiguredTooling.new("Invalid .yarnrc.yml file", message)
        end

        raise
      end

      sig { returns(T::Boolean) }
      def self.yarn_zero_install?
        File.exist?(".pnp.cjs")
      end

      sig { returns(T::Boolean) }
      def self.yarn_offline_cache?
        yarn_cache_dir = fetch_yarnrc_yml_value("cacheFolder", ".yarn/cache")
        File.exist?(yarn_cache_dir) && (fetch_yarnrc_yml_value("nodeLinker", "") == "node-modules")
      end

      sig { returns(String) }
      def self.yarn_berry_args
        if yarn_major_version == 2
          ""
        elsif yarn_berry_skip_build?
          "--mode=skip-build"
        else
          # We only want this mode if the cache is not being updated/managed
          # as this improperly leaves old versions in the cache
          "--mode=update-lockfile"
        end
      end

      sig { returns(T::Boolean) }
      def self.yarn_berry_skip_build?
        yarn_major_version >= YARN_V3 && (yarn_zero_install? || yarn_offline_cache?)
      end

      sig { returns(T::Boolean) }
      def self.yarn_berry_disable_scripts?
        yarn_major_version == YARN_V2 || !yarn_zero_install?
      end

      sig { returns(T::Boolean) }
      def self.yarn_4_or_higher?
        yarn_major_version >= 4
      end

      sig { returns(T.nilable(String)) }
      def self.setup_yarn_berry
        # Always disable immutable installs so yarn's CI detection doesn't prevent updates.
        run_single_yarn_command("config set enableImmutableInstalls false")
        # Do not generate a cache if offline cache disabled. Otherwise side effects may confuse further checks
        run_single_yarn_command("config set enableGlobalCache true") unless yarn_berry_skip_build?
        # We never want to execute postinstall scripts, either set this config or mode=skip-build must be set
        run_single_yarn_command("config set enableScripts false") if yarn_berry_disable_scripts?
        if (http_proxy = ENV.fetch("HTTP_PROXY", false))
          run_single_yarn_command("config set httpProxy #{http_proxy}", fingerprint: "config set httpProxy <proxy>")
        end
        if (https_proxy = ENV.fetch("HTTPS_PROXY", false))
          run_single_yarn_command("config set httpsProxy #{https_proxy}", fingerprint: "config set httpsProxy <proxy>")
        end
        return unless (ca_file_path = ENV.fetch("NODE_EXTRA_CA_CERTS", false))

        if yarn_4_or_higher?
          run_single_yarn_command("config set httpsCaFilePath #{ca_file_path}")
        else
          run_single_yarn_command("config set caFilePath #{ca_file_path}")
        end
      end

      # Run any number of yarn commands while ensuring that `enableScripts` is
      # set to false. Yarn commands should _not_ be ran outside of this helper
      # to ensure that postinstall scripts are never executed, as they could
      # contain malicious code.
      sig { params(commands: T::Array[String]).void }
      def self.run_yarn_commands(*commands)
        setup_yarn_berry
        commands.each do |cmd, fingerprint|
          run_single_yarn_command(cmd, fingerprint: fingerprint) if cmd
        end
      end

      # Run single npm command returning stdout/stderr.
      #
      # NOTE: Needs to be explicitly run through corepack to respect the
      # `packageManager` setting in `package.json`, because corepack does not
      # add shims for NPM.
      sig { params(command: String, fingerprint: T.nilable(String)).returns(String) }
      def self.run_npm_command(command, fingerprint: command)
        if Dependabot::Experiments.enabled?(:enable_corepack_for_npm_and_yarn)
          package_manager_run_command(
            NpmPackageManager::NAME,
            command,
            fingerprint: fingerprint,
            output_observer: ->(output) { command_observer(output) }
          )
        else
          Dependabot::SharedHelpers.run_shell_command(
            "npm #{command}",
            fingerprint: "npm #{fingerprint}",
            output_observer: ->(output) { command_observer(output) }
          )
        end
      end

      sig do
        params(output: String)
          .returns(T::Hash[Symbol, T.untyped])
      end
      def self.command_observer(output)
        # Observe the output for specific error
        return {} unless output.include?("npm ERR! ERESOLVE")

        {
          gracefully_stop: true, # value must be a String
          reason: "NPM Resolution Error"
        }
      end

      sig { returns(T.nilable(String)) }
      def self.node_version
        version = run_node_command("-v", fingerprint: "-v").strip

        # Validate the output format (e.g., "v20.18.1" or "20.18.1")
        if version.match?(/^v?\d+(\.\d+){2}$/)
          version.strip.delete_prefix("v") # Remove the "v" prefix if present
        end
      rescue StandardError => e
        Dependabot.logger.error("Error retrieving Node.js version: #{e.message}")
        nil
      end

      sig { params(command: String, fingerprint: T.nilable(String)).returns(String) }
      def self.run_node_command(command, fingerprint: nil)
        full_command = "node #{command}"

        Dependabot.logger.info("Running node command: #{full_command}")

        result = Dependabot::SharedHelpers.run_shell_command(
          full_command,
          fingerprint: "node #{fingerprint || command}"
        )

        Dependabot.logger.info("Command executed successfully: #{full_command}")
        result
      rescue StandardError => e
        Dependabot.logger.error("Error running node command: #{full_command}, Error: #{e.message}")
        raise
      end

      sig { returns(T.nilable(String)) }
      def self.bun_version
        version = run_bun_command("--version", fingerprint: "--version").strip
        if version.include?("+")
          version.split("+").first # Remove build info, if present
        end
      rescue StandardError => e
        Dependabot.logger.error("Error retrieving Bun version: #{e.message}")
        nil
      end

      sig { params(command: String, fingerprint: T.nilable(String)).returns(String) }
      def self.run_bun_command(command, fingerprint: nil)
        full_command = "bun #{command}"

        Dependabot.logger.info("Running bun command: #{full_command}")

        result = Dependabot::SharedHelpers.run_shell_command(
          full_command,
          fingerprint: "bun #{fingerprint || command}"
        )

        Dependabot.logger.info("Command executed successfully: #{full_command}")
        result
      rescue StandardError => e
        Dependabot.logger.error("Error running bun command: #{full_command}, Error: #{e.message}")
        raise
      end

      # Setup yarn and run a single yarn command returning stdout/stderr
      sig { params(command: String, fingerprint: T.nilable(String)).returns(String) }
      def self.run_yarn_command(command, fingerprint: nil)
        setup_yarn_berry
        run_single_yarn_command(command, fingerprint: fingerprint)
      end

      # Run single pnpm command returning stdout/stderr
      sig { params(command: String, fingerprint: T.nilable(String)).returns(String) }
      def self.run_pnpm_command(command, fingerprint: nil)
        if Dependabot::Experiments.enabled?(:enable_corepack_for_npm_and_yarn)
          package_manager_run_command(PNPMPackageManager::NAME, command, fingerprint: fingerprint)
        else
          Dependabot::SharedHelpers.run_shell_command(
            "pnpm #{command}",
            fingerprint: "pnpm #{fingerprint || command}"
          )
        end
      end

      # Run single yarn command returning stdout/stderr
      sig { params(command: String, fingerprint: T.nilable(String)).returns(String) }
      def self.run_single_yarn_command(command, fingerprint: nil)
        if Dependabot::Experiments.enabled?(:enable_corepack_for_npm_and_yarn)
          package_manager_run_command(YarnPackageManager::NAME, command, fingerprint: fingerprint)
        else
          Dependabot::SharedHelpers.run_shell_command(
            "yarn #{command}",
            fingerprint: "yarn #{fingerprint || command}"
          )
        end
      end

      # Install the package manager for specified version by using corepack
      sig do
        params(
          name: String,
          version: String,
          env: T.nilable(T::Hash[String, String])
        )
          .returns(String)
      end
      def self.install(name, version, env: {})
        Dependabot.logger.info("Installing \"#{name}@#{version}\"")

        begin
          # Try to install the specified version
          output = package_manager_install(name, version, env: env)

          # Confirm success based on the output
          if output.match?(/Adding #{name}@.* to the cache/)
            Dependabot.logger.info("#{name}@#{version} successfully installed.")

            Dependabot.logger.info("Activating currently installed version of #{name}: #{version}")
            package_manager_activate(name, version)

          else
            Dependabot.logger.error("Corepack installation output unexpected: #{output}")
            fallback_to_local_version(name)
          end
        rescue StandardError => e
          Dependabot.logger.error("Error installing #{name}@#{version}: #{e.message}")
          fallback_to_local_version(name)
        end

        # Verify the installed version
        installed_version = package_manager_version(name)

        installed_version
      end

      # Attempt to activate the local version of the package manager
      sig { params(name: String).void }
      def self.fallback_to_local_version(name)
        return "Corepack does not support #{name}" unless corepack_supported_package_manager?(name)

        Dependabot.logger.info("Falling back to activate the currently installed version of #{name}.")

        # Fetch the currently installed version directly from the environment
        current_version = local_package_manager_version(name)
        Dependabot.logger.info("Activating currently installed version of #{name}: #{current_version}")

        # Prepare the existing version
        package_manager_activate(name, current_version)
      end

      # Install the package manager for specified version by using corepack
      sig do
        params(
          name: String,
          version: String,
          env: T.nilable(T::Hash[String, String])
        )
          .returns(String)
      end
      def self.package_manager_install(name, version, env: {})
        return "Corepack does not support #{name}" unless corepack_supported_package_manager?(name)

        Dependabot::SharedHelpers.run_shell_command(
          "corepack install #{name}@#{version} --global --cache-only",
          fingerprint: "corepack install <name>@<version> --global --cache-only",
          env: env
        ).strip
      end

      # Prepare the package manager for use by using corepack
      sig { params(name: String, version: String).returns(String) }
      def self.package_manager_activate(name, version)
        return "Corepack does not support #{name}" unless corepack_supported_package_manager?(name)

        Dependabot::SharedHelpers.run_shell_command(
          "corepack prepare #{name}@#{version} --activate",
          fingerprint: "corepack prepare <name>@<version> --activate"
        ).strip
      end

      # Fetch the currently installed version of the package manager directly
      # from the system without involving Corepack
      sig { params(name: String).returns(String) }
      def self.local_package_manager_version(name)
        Dependabot::SharedHelpers.run_shell_command(
          "#{name} -v",
          fingerprint: "#{name} -v"
        ).strip
      end

      # Get the version of the package manager by using corepack
      sig { params(name: String).returns(String) }
      def self.package_manager_version(name)
        Dependabot.logger.info("Fetching version for package manager: #{name}")

        version = package_manager_run_command(name, "-v").strip

        Dependabot.logger.info("Installed version of #{name}: #{version}")

        version
      rescue StandardError => e
        Dependabot.logger.error("Error fetching version for package manager #{name}: #{e.message}")
        raise
      end

      # Run single command on package manager returning stdout/stderr
      sig do
        params(
          name: String,
          command: String,
          fingerprint: T.nilable(String),
          output_observer: CommandHelpers::OutputObserver
        ).returns(String)
      end
      def self.package_manager_run_command(
        name,
        command,
        fingerprint: nil,
        output_observer: nil
      )
        return run_bun_command(command, fingerprint: fingerprint) if name == BunPackageManager::NAME

        full_command = "corepack #{name} #{command}"
        fingerprint =  "corepack #{name} #{fingerprint || command}"

        if output_observer
          return Dependabot::SharedHelpers.run_shell_command(
            full_command,
            fingerprint: fingerprint,
            output_observer: output_observer
          ).strip
        else
          Dependabot::SharedHelpers.run_shell_command(full_command, fingerprint: fingerprint)
        end.strip
      rescue StandardError => e
        Dependabot.logger.error("Error running package manager command: #{full_command}, Error: #{e.message}")
        if e.message.match?(/Response Code.*:.*404.*\(Not Found\)/) &&
           e.message.include?("The remote server failed to provide the requested resource")
          raise RegistryError.new(404, "The remote server failed to provide the requested resource")
        end

        raise
      end

      private_class_method :run_single_yarn_command

      sig { params(pnpm_lock: DependencyFile).returns(T.nilable(String)) }
      def self.pnpm_lockfile_version(pnpm_lock)
        match = T.must(pnpm_lock.content).match(/^lockfileVersion: ['"]?(?<version>[\d.]+)/)
        return match[:version] if match

        nil
      end

      sig { params(dependency_set: Dependabot::FileParsers::Base::DependencySet).returns(T::Array[Dependency]) }
      def self.dependencies_with_all_versions_metadata(dependency_set)
        dependency_set.dependencies.map do |dependency|
          dependency.metadata[:all_versions] = dependency_set.all_versions_for_name(dependency.name)
          dependency
        end
      end

      sig { params(name: String).returns(T::Boolean) }
      def self.corepack_supported_package_manager?(name)
        SUPPORTED_COREPACK_PACKAGE_MANAGERS.include?(name)
      end
    end
  end
end
