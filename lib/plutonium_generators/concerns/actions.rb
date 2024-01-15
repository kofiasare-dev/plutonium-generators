# frozen_string_literal: true

require "yaml"
require "erb"
require "open3"
require "fileutils"

module PlutoniumGenerators
  module Concerns
    module Actions
      protected

      #
      # Sets the ruby version for the project in .ruby-version and Gemfile to `PlutoniumGenerators::RUBY_VERSION`
      #
      # @return [void]
      #
      def set_ruby_version!
        log :set_ruby_version!, PlutoniumGenerators::RUBY_VERSION

        in_root do
          create_file ".ruby-version", PlutoniumGenerators::RUBY_VERSION, force: true, verbose: false
          gsub_file "Gemfile", /^ruby ["'].*["']/, "ruby '~> #{PlutoniumGenerators::RUBY_VERSION}'", verbose: false
        end
      end

      #
      # Adds a new gem into the Gemfile
      # Existing directives are updated if they do not match
      # When `:group` is specified, the gem is inserted into the approriate gem group.
      #
      # @param [String] name the name of the gem
      # @param [Hash] **kwargs set of options to append see #super
      #
      # @return [void]
      #
      def gem(name, **kwargs)
        groups = Array(kwargs.delete(:group))

        in_root do
          begin
            # Create a temp gemfile
            File.rename("Gemfile", "Gemfile.bak")
            File.write("Gemfile", "")
            # Generate the directive
            super
            # Get the generated directive
            directive = gemfile.strip
          ensure
            # Restore our gemfile
            File.delete "Gemfile"
            File.rename "Gemfile.bak", "Gemfile"
          end

          pattern = /^# gem ['"]#{name}['"].*/
          if gemfile.match(pattern)
            # Replace commented out directive
            gsub_file("Gemfile", pattern, directive)
            break
          end

          # Remove existing directive
          remove_gem name

          # Insert the new directive
          if groups != []
            str = groups.sort.map(&:inspect).join(", ")
            after_sentinel = "group #{str} do\n"

            unless File.read("Gemfile").match?(/^#{after_sentinel}/)
              inject_into_file "Gemfile", "\n#{after_sentinel}end\n"
            end
          else
            after_sentinel = "# Project gems\n\n"
            unless File.read("Gemfile").match?(/^#{after_sentinel}/)
              inject_into_file "Gemfile", "\n#{after_sentinel}", after: /^ruby .*\n/
            end
          end

          inject_into_file "Gemfile", "#{directive}\n", after: /^#{after_sentinel}/
        end
      end

      #
      # Removes a gem and any preceeding comments from the Gemfile
      #
      # @param gem [String] the name of the gem to remove
      #
      # @return [void]
      #
      def remove_gem(gem)
        log :remove_gem, gem
        gsub_file "Gemfile", /(:?^.*#.*\n)*.*gem ['"]#{gem}['"].*\n/, "", verbose: false
      end

      #
      # Evaluates the given template and merges it with the project's docker-compose.yml
      #
      # @param [String] source the template filename
      #
      # @return [void]
      #
      def docker_compose(source)
        log :docker_compose, source

        in_root do
          compose_file = "docker-compose.yml"
          compose_definition = YAML.load_file(compose_file) if File.exist?(compose_file)
          compose_definition ||= {
            version: "3.7",
            services: {}
          }
          compose_definition.deep_stringify_keys!

          new_definition = YAML.load template_eval("docker-compose/#{source}.yml.tt")
          compose_definition.deep_merge! new_definition.deep_stringify_keys

          create_file compose_file, YAML.dump(compose_definition), force: true
        end
      end

      #
      # Duplicates a project file
      #
      # @param [<Type>] src the source filename
      # @param [<Type>] dest the destination filename
      #
      # @return [<Type>] <description>
      #
      def duplicate_file(src, dest)
        log :duplicate_file, "#{src} -> #{dest}"

        in_root do
          FileUtils.cp src, dest
        rescue => e
          exception "An error occurred while copying the file '#{src}' to '#{dest}'", e
        end
      end

      #
      # Insert a new process into the Procfile
      #
      # @param [<Type>] proc the process name e.g. `:web`
      # @param [<Type>] command the command to run to start the process e.g. `bundle exec rails server -p $PORT`
      # @param [<Type>] env use an environment specific Procfile e.g. `env: :dev` -> Procfile.dev
      #
      # @return [<Type>] <description>
      #
      def proc_file(proc, command, env: nil)
        directive = "#{proc}: #{command}"
        filename = env ? "Procfile.#{env}" : "Procfile"

        log :proc_file, directive

        in_root do
          File.write(filename, "") unless File.exist? filename

          pattern = /^#{proc}:.*/
          if File.read(filename).match?(pattern)
            gsub_file filename, pattern, directive
          else
            insert_into_file filename, "#{directive}\n"
          end
        end
      end

      #
      # Creates an initializer from a template file
      #
      # @param [String] filename the initializer filename
      # @param [String] template the template filename
      #
      # @return [void]
      #
      def template_initializer(filename, template)
        log :template_initializer, filename

        initializer filename do
          template_eval template
        end
      end

      def environment(data = nil, options = {})
        data ||= yield if block_given?

        log :environment, data

        in_root do
          def replace_existing(file, data)
            gsub_file file, Regexp.new(".*#{data.split("=").first.strip}.*=.*\n"), data, verbose: false
          end

          if options[:env].nil?
            data = optimize_indentation(data, 4)
            file = "config/application.rb"
            replace_existing file, data
            break if File.read(file).match? regexify_config(data)

            inject_into_file file, "\n#{data}", before: /^  end\nend/, verbose: false
          else
            data = optimize_indentation(data, 2)

            Array(options[:env]).each do |env|
              file = "config/environments/#{env}.rb"
              replace_existing file, data
              next if File.read(file).match? regexify_config(data)

              inject_into_file file, data, before: /^end/,
                verbose: false
            end
          end
        end
      end

      #
      # Set a config in the application generator block
      # If the configuration exists already, it is updated
      #
      # @param [String] data configuration string. e.g. `g.helper :my_helper`
      # @param [Hash] options optional options hash
      # @option options [String, Array(String), Array(Symbol)] :env environment specification config to update
      #
      # @return [void]
      #
      def environment_generator(data = nil, options = {})
        data ||= yield if block_given?

        log :environment_generator, data

        in_root do
          def replace_existing(file, data)
            gsub_file file, Regexp.new(".*#{data.split("=").first.strip}.*=.*\n"), data, verbose: false
          end

          def ensure_sentinel(file, sentinel)
            return if File.read(file).match?(/^#{Regexp.quote sentinel}/)

            inject_into_file file, "\n#{sentinel}#{optimize_indentation("end", 4)}", before: /^  end\nend/,
              verbose: false
          end

          sentinel = optimize_indentation("config.generators do |g|\n", 4)

          if options[:env].nil?
            data = optimize_indentation(data, 6)
            file = "config/application.rb"
            replace_existing file, data
            break if File.read(file).match? regexify_config(data)

            ensure_sentinel file, sentinel
            inject_into_file file, data, after: sentinel, verbose: false
          else
            data = optimize_indentation(data, 2)

            Array(options[:env]).each do |env|
              file = "config/environments/#{env}.rb"
              replace_existing file, data
              next if File.read(file).match? regexify_config(data)

              ensure_sentinel file, sentinel
              inject_into_file file, data, after: sentinel, verbose: false
            end
          end
        end
      end

      #
      # Insert the given directives into .gitignore
      #
      # @param [String] *directives directives to ignore
      #
      # @return [void]
      #
      def gitignore(*directives)
        in_root do
          # Doing this one by one so that duplication detection during insertion will work
          directives.each do |directive|
            log :gitignore, directive
            insert_into_file ".gitignore", "#{directive}\n", verbose: false
          end
        end
      end

      #
      # Similar to #run, this executes a command but returns both success and output
      #
      # @param command [String] the command to run
      #
      # @return [bool, String] success, output
      #
      def run_eval(command, config = {})
        return [false, nil] unless behavior == :invoke

        destination = relative_to_original_destination_root(destination_root, false)
        desc = "#{command} from #{destination.inspect}"

        if config[:with]
          desc = "#{File.basename(config[:with].to_s)} #{desc}"
          command = "#{config[:with]} #{command}"
        end

        say_status :run, desc, config.fetch(:verbose, true)

        return if options[:pretend]

        env_splat = [config[:env]] if config[:env]

        output, status = Open3.capture2e(*env_splat, command.to_s)
        success = status.success?

        [success, output]
      end

      private

      #
      # <Description>
      #
      # @param [String] source the template file path
      #
      # @return [String] the rendered template contents
      #
      def template_eval(source)
        source = File.binread File.expand_path(find_in_source_paths(source.to_s))
        ERB.new(source, trim_mode: "-").result(binding)
      end

      #
      # Converts a config string into a regular expression
      # This string is quoted and achored to the start of the line.
      # If quotes are present, the match is made invariant e.g. `'` or `"` will match both `'` and `"`
      #
      # @param [String] str the string to convert into a pattern
      #
      # @return [String] the new regex
      #
      def regexify_config(str)
        Regexp.new("^#{Regexp.quote str}".gsub(/['"]/, %(['"])))
      end

      #
      # Returns the contents of the Gemfile
      #
      # @return [String] the rendered of the Gemfile
      #
      def gemfile
        in_root do
          File.read("Gemfile")
        end
      end
    end
  end
end
