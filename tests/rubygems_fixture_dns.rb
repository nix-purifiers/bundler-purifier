# SPDX-License-Identifier: MIT
# Route the genuine SDK's optional endpoint discovery to the owned DNS
# fixture, alongside the owned HTTP registry. Keep its real resolver and
# update check; no public DNS server is required by this local test.
require "rubygems"
require "rubygems/remote_fetcher"
if ENV["PURIFIER_FIXTURE_DNS_PORT"] && Gem::RemoteFetcher.method_defined?(:api_endpoint)
  require "resolv"
  dns = Resolv::DNS.new(:nameserver_port => [["127.0.0.1", Integer(ENV.fetch("PURIFIER_FIXTURE_DNS_PORT"))]],
                        :search => [], :ndots => 1)
  fetcher = Gem::RemoteFetcher.new(Gem.configuration[:http_proxy], dns)
  Gem::RemoteFetcher.instance_variable_set(:@fetcher, fetcher)
end
