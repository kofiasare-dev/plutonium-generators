# frozen_string_literal: true

require File.expand_path("../../../../plutonium_generators", __dir__)

module Pu
  module Pkg
    class AppGenerator < Rails::Generators::Base
      include PlutoniumGenerators::Generator

      source_root File.expand_path("templates", __dir__)

      desc "Create a plutonium app package"

      argument :name

      def start
        validate_package_name package_name

        if defined?(RodauthApp) && (rodauths = RodauthApp.opts[:rodauths].keys).present?
          rodauth_account = prompt.select("Select rodauth account to authenticate with:", rodauths + [:none])
          @rodauth_account = rodauth_account unless rodauth_account == :none
        end

        template "lib/engine.rb", "packages/#{package_namespace}/lib/engine.rb"
        template "config/routes.rb", "packages/#{package_namespace}/config/routes.rb"

        %w[controllers interactions models policies presenters].each do |dir|
          directory "app/#{dir}", "packages/#{package_namespace}/app/#{dir}/#{package_namespace}"
        end
        create_file "packages/#{package_namespace}/app/views/#{package_namespace}/.keep"

        insert_into_file "config/packages.rb", "require_relative \"../packages/#{package_namespace}/lib/engine\"\n"
      rescue => e
        exception "#{self.class} failed:", e
      end

      private

      attr_reader :rodauth_account

      def package_name
        name.classify + "App"
      end

      def package_namespace
        package_name.underscore
      end

      def package_type
        "App"
      end
    end
  end
end
