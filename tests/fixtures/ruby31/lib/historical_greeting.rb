require "json"
module HistoricalGreeting
  def self.answer
    raise "wrong JSON" unless JSON::VERSION == "2.9.1"
    raise "parser is not native" unless $LOADED_FEATURES.any? { |path| path =~ /json\/ext\/parser\.(so|bundle)$/ }
    JSON.parse('{"answer":42}').fetch("answer")
  end
end
