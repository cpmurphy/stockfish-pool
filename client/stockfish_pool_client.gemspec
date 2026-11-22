# frozen_string_literal: true

require_relative 'lib/stockfish_pool/client/version'

Gem::Specification.new do |spec|
  spec.name = 'stockfish_pool_client'
  spec.version = StockfishPool::Client::VERSION
  spec.summary = 'Client for the stockfish-pool engine service'
  spec.description = 'Calls a stockfish-pool service over HTTP/JSON and returns typed results and errors.'
  spec.authors = ['Christian Murphy']
  spec.email = ['cpm@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/cpmurphy/stockfish-pool'
  spec.required_ruby_version = '>= 3.0'
  spec.files = Dir['lib/**/*.rb', 'README.md']
  spec.require_paths = ['lib']
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/cpmurphy/stockfish-pool'
  spec.metadata['rubygems_mfa_required'] = 'true'
  # Only the standard library (net/http, json) is used at runtime.
end
