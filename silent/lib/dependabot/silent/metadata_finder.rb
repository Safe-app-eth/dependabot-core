# typed: strong
# frozen_string_literal: true

require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"

module Dependabot
  module Silent
    class MetadataFinder < Dependabot::MetadataFinders::Base
      extend T::Sig

      sig { returns(String) }
      def homepage_url
        ""
      end

      private

      sig { override.returns(Dependabot::Source) }
      def look_up_source
        # Use 127.0.0.1 as a non-routable hostname to avoid network requests
        # This ensures the silent package manager remains truly "silent"
        Dependabot::Source.new(
          provider: "example",
          hostname: "127.0.0.1",
          api_endpoint: "http://127.0.0.1/api/v3",
          repo: dependency.name,
          directory: nil,
          branch: nil
        )
      end
    end
  end
end
