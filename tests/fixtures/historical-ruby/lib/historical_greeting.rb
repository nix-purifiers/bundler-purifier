require "json"
module HistoricalGreeting
  def self.answer
    raise "wrong JSON" unless JSON::VERSION == "1.8.6"
    raise "parser is not native" unless JSON::Ext::Parser.instance_method(:parse).source_location.nil?
    JSON.parse('{"answer":42}').fetch("answer")
  end
end
