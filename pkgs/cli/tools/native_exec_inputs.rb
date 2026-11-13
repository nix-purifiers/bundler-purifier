# SPDX-License-Identifier: MIT
# Install only in an input-bound early YAML CLI process. Its native exec
# prepends bundler/setup after the facade has already been evaluated.
module PurifierNativeExecInputs
  REQUIRE = "-r" + File.expand_path("rubygems_inputs", File.dirname(__FILE__))

  def self.install
    singleton = class << Kernel; self; end
    return if singleton.method_defined?(:purifier_exec_without_input_bootstrap)
    singleton.class_eval do
      alias_method :purifier_exec_without_input_bootstrap, :exec
      def exec(*arguments)
        previous = ENV["RUBYOPT"]
        unless previous.to_s.split.include?(PurifierNativeExecInputs::REQUIRE)
          ENV["RUBYOPT"] = PurifierNativeExecInputs::REQUIRE + (previous ? " " + previous : "")
        end
        begin
          purifier_exec_without_input_bootstrap(*arguments)
        ensure
          previous ? ENV["RUBYOPT"] = previous : ENV.delete("RUBYOPT")
        end
      end
    end
  end
end
