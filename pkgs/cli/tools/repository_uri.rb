# SPDX-License-Identifier: MIT
# Older Ruby and vendored Bundler URI classes serialize an empty file
# authority differently. Keep host, path, escapes and query bytes distinct.
module PurifierRepositoryURI
  def self.identity(uri)
    uri.to_s.sub(/\Afile:\/\/(?=\/)/, "file:").sub(/\/$/, "")
  end
end
