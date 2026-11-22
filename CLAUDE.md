# stockfish-pool/

Self-contained HTTP/JSON service (own Gemfile, tests and `.rubocop.yml`) that
runs a fixed, sandboxable pool of Stockfish engines. `client/` is the Ruby
client gem; apps depend on it via a git tag of this repository (not rubygems.org).

```bash
bundle install
bundle exec rake test
API_TOKENS=dev-token-0123456789abcdefgh bundle exec puma -C config/puma.rb
deploy/build-image.sh
```

**Chess rules:** `lib/stockfish_pool/rules/` (`StockfishPool::Rules`) is the
source of truth for the shared position/move legality code. Apps that keep a
`ChessRules` copy sync *from* this tree (see `bin/export-chess-rules`). Do not
edit app copies and push back here.
