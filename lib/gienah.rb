# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "pathname"

require_relative "gienah/version"

module Gienah
  Value = if defined?(Data)
    Module.new do
      module_function
      def define(*members) = Data.define(*members)
    end
  else
    Module.new do
      module_function
      def define(*members)
        Struct.new(*members) do
          define_method(:initialize) do |*values, **keywords|
            values = members.map { |member| keywords.fetch(member) } if values.empty? && !keywords.empty?
            super(*values)
            freeze
          end
        end
      end
    end
  end
end

require_relative "gienah/protocol"
require_relative "gienah/future"
require_relative "gienah/manifest"
require_relative "gienah/sandbox"
require_relative "gienah/transport"
require_relative "gienah/host"
require_relative "gienah/plugin"
require_relative "gienah/testing/fake_plugin"

module Gienah
  class Error < StandardError; end
  class CapabilityDenied < Error; end
  class Timeout < Error; end
  class ProtocolError < Error; end
  class LifecycleError < Error; end
end
