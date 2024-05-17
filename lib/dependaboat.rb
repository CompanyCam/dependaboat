require "logger"
require "ghx"

module Dependaboat
  def self.logger
    @logger ||= Logger.new($stdout)
  end

  def self.logger=(logger)
    @logger = logger
  end
end

require_relative "version"
require_relative "dependaboat/cli"
