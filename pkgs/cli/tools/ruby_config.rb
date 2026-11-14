# SPDX-License-Identifier: MIT
# Read the module actually provided by this SDK; do not add an RbConfig alias.
require "rbconfig"
module PurifierRubyConfig
  def self.values
    defined?(RbConfig) ? RbConfig::CONFIG : Config::CONFIG
  end
end
