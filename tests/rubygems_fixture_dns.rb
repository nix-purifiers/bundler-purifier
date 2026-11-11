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
  # Older Resolv predates nameserver_port configuration, but its genuine
  # connected UDP requester already accepts an explicit port. Select that
  # transport only on this owned resolver instance; retain native DNS wire
  # parsing, NXDOMAIN handling and RubyGems' endpoint fallback.
  configuration = dns.instance_variable_get(:@config)
  if configuration.respond_to?(:nameserver_port)
    # Ruby 1.8.7 backports the native port reader but not its constructor
    # option. Populate its owned native cache after lazy initialization.
    endpoints = [["127.0.0.1", Integer(ENV.fetch("PURIFIER_FIXTURE_DNS_PORT"))]]
    unless configuration.nameserver_port == endpoints
      configuration.instance_variable_set(:@nameserver_port, endpoints)
      raise "fixture DNS port was not selected" unless configuration.nameserver_port == endpoints
    end
  else
    dns.instance_variable_set(:@purifier_fixture_port, Integer(ENV.fetch("PURIFIER_FIXTURE_DNS_PORT")))
    def dns.make_requester
      Resolv::DNS::Requester::ConnectedUDP.new("127.0.0.1", @purifier_fixture_port)
    end
  end
  fetcher = Gem::RemoteFetcher.new(Gem.configuration[:http_proxy], dns)
  Gem::RemoteFetcher.instance_variable_set(:@fetcher, fetcher)
end
