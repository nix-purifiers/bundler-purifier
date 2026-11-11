# SPDX-License-Identifier: MIT
# Route the genuine SDK's optional endpoint discovery to the owned DNS
# fixture, alongside the owned HTTP registry. Keep its real resolver and
# update check; no public DNS server is required by this local test.
require "rubygems"
require "rubygems/remote_fetcher"
if ENV["PURIFIER_FIXTURE_DNS_PORT"] && Gem::RemoteFetcher.method_defined?(:api_endpoint)
  require "resolv"
  dns = Resolv::DNS.new(:nameserver => ["127.0.0.1"], :nameserver_port => [["127.0.0.1", Integer(ENV.fetch("PURIFIER_FIXTURE_DNS_PORT"))]],
                        :search => [], :ndots => 1)
  # Ruby 1.9.1 predates nameserver_port configuration, but its genuine
  # connected UDP requester already accepts an explicit port. Select that
  # transport only on this owned resolver instance; retain native DNS wire
  # parsing, NXDOMAIN handling and RubyGems' endpoint fallback.
  if RUBY_VERSION == "1.9.1"
    dns.instance_variable_set(:@purifier_fixture_port, Integer(ENV.fetch("PURIFIER_FIXTURE_DNS_PORT")))
    def dns.make_requester
      Resolv::DNS::Requester::ConnectedUDP.new("127.0.0.1", @purifier_fixture_port)
    end
  end
  fetcher = Gem::RemoteFetcher.new(Gem.configuration[:http_proxy], dns)
  Gem::RemoteFetcher.instance_variable_set(:@fetcher, fetcher)
end
