# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fake_worker'
require 'rack/test'
require 'json'

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include TestSupport

  def app
    @app ||= begin
      @config = config(@overrides || {})
      pool = StockfishPool::Pool.new(config: @config, worker_factory: -> { FakeWorker.new }, logger: null_logger)
      @service = StockfishPool::Service.new(config: @config, pool: pool).start(supervise: false)
      StockfishPool::App.new(service: @service)
    end
  end

  def teardown
    @service&.shutdown
  end

  def analyze(body, token: TOKEN)
    header 'Authorization', "Bearer #{token}" if token
    post '/v1/analyze', body.is_a?(String) ? body : body.to_json, 'CONTENT_TYPE' => 'application/json'
    JSON.parse(last_response.body)
  end

  def test_analyze_returns_lines_and_applied_limits
    body = analyze({ fen: START_FEN, depth: 40, multipv: 2 })

    assert_equal 200, last_response.status
    assert_equal 'e2e4', body['bestmove']
    assert_equal({ 'depth' => 18, 'movetime_ms' => 100, 'nodes' => 2_000_000, 'multipv' => 2 }, body['applied'])
    assert_equal 'interactive', body['lane']
  end

  def test_requires_a_valid_token
    analyze({ fen: START_FEN }, token: nil)

    assert_equal 401, last_response.status
    analyze({ fen: START_FEN }, token: 'wrong-token-0123456789abcdef')

    assert_equal 401, last_response.status
  end

  def test_rejects_injection_with_422
    body = analyze({ fen: "#{START_FEN}\nsetoption name Threads value 1024" })

    assert_equal 422, last_response.status
    assert_equal 'invalid_request', body['error']
  end

  # Stockfish would silently skip an illegal move, or may crash on an illegal
  # position, so neither reaches a worker.
  def test_rejects_illegal_moves_and_positions_with_422
    searches_before = FakeWorker.registry.sum { |worker| worker.searches.size }
    [
      [{ fen: START_FEN, moves: %w[e2e4 e2e4] }, 'Illegal move e2e4 (moves[1])'],
      [{ fen: '4k3/1P6/8/8/8/8/8/4K3 w - - 0 1', moves: %w[b7b8] }, 'Illegal move b7b8 (moves[0])'],
      [{ fen: '8/8/8/3kK3/8/8/8/8 w - - 0 1' }, 'Illegal position: the side not to move is in check'],
      [{ fen: '4k3/8/8/8/8/8/8/4K3 w KQkq - 0 1' }, /\AIllegal position: castling right K/]
    ].each do |body, message|
      response = analyze(body)

      assert_equal 422, last_response.status, body.to_s
      assert_match message.is_a?(Regexp) ? message : /\A#{Regexp.escape(message)}\z/, response['message']
    end
    assert_equal(searches_before, FakeWorker.registry.sum { |worker| worker.searches.size })
  end

  # Malformed requests are refused with a 422 naming the problem, before any
  # search reaches a worker. Bodies given as strings are sent as they are.
  def test_rejects_malformed_requests_with_422
    searches_before = FakeWorker.registry.sum { |worker| worker.searches.size }
    [
      ['[]', 'Request body must be a JSON object'],
      ['"e2e4"', 'Request body must be a JSON object'],
      ['42', 'Request body must be a JSON object'],
      ['null', 'Request body must be a JSON object'],
      [{ fen: START_FEN, moves: 'e2e4' }, 'moves must be an array'],
      [{ fen: START_FEN, moves: { 'e2e4' => true } }, 'moves must be an array'],
      [{ fen: START_FEN, moves: (%w[e2e4 e7e5] * 300) + ['g1f3'] }, 'At most 600 moves are allowed'],
      [{ fen: START_FEN, moves: ['Nf3'] }, 'Invalid UCI move'],
      [{ fen: START_FEN, depth: 0 }, 'depth must be a positive integer'],
      [{ fen: START_FEN, depth: -1 }, 'depth must be a positive integer'],
      [{ fen: START_FEN, depth: '16' }, 'depth must be a positive integer'],
      [{ fen: START_FEN, depth: true }, 'depth must be a positive integer'],
      [{ fen: START_FEN, multipv: 1.5 }, 'multipv must be a positive integer'],
      [{ fen: START_FEN, nodes: '1000' }, 'nodes must be a positive integer'],
      [{ fen: START_FEN, movetime_ms: 0 }, 'movetime_ms must be a positive integer'],
      [{ fen: START_FEN, subject: "abc\ndef" }, 'Invalid subject'],
      [{ fen: START_FEN, subject: 'a' * 65 }, 'Invalid subject'],
      [{ fen: START_FEN, subject: '' }, 'Invalid subject'],
      [{ fen: START_FEN, subject: 42 }, 'Invalid subject'],
      [{ fen: START_FEN, lane: 'urgent' }, 'lane must be "interactive" or "batch"'],
      [{}, 'Invalid FEN'],
      [{ fen: 42 }, 'Invalid FEN'],
      [{ fen: "#{START_FEN}#{' ' * 60}" }, 'Invalid FEN'], # over 100 characters
      [{ fen: 'rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1' }, 'Invalid FEN'], # a rank of 9 squares
      [{ fen: 'rnbqkbnr/pppppppp/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1' }, 'Invalid FEN'], # 7 ranks
      [{ fen: 'rnbqkbnr/pppppppp/8/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1' }, 'Invalid FEN'], # 9 ranks
      [{ fen: '4k3/8/8/8/8/P7/PPPPPPPP/4K3 w - - 0 1' }, # nine white pawns
       'Illegal position: White has more pieces than a game can produce'],
      [{ fen: 'qqq1k3/pppppppp/8/8/8/8/8/4K3 w - - 0 1' }, # two promoted queens, no pawn missing
       'Illegal position: Black has more pieces than a game can produce']
    ].each do |body, message|
      response = analyze(body)

      assert_equal 422, last_response.status, body.to_s
      assert_equal 'invalid_request', response['error'], body.to_s
      assert_equal message, response['message'], body.to_s
    end
    assert_equal(searches_before, FakeWorker.registry.sum { |worker| worker.searches.size })
  end

  def test_rejects_bad_json_and_large_bodies
    analyze('{not json')

    assert_equal 400, last_response.status
    analyze({ fen: START_FEN, padding: 'x' * 20_000 })

    assert_equal 413, last_response.status
  end

  def test_subject_quota_returns_429_with_retry_after
    @overrides = { 'SUBJECT_BURST_SEC' => '1', 'SUBJECT_ENGINE_SEC_PER_MIN' => '1' }
    app
    @service.quota(:interactive).charge('client-1', 5)
    body = analyze({ fen: START_FEN, subject: 'client-1' })

    assert_equal 429, last_response.status
    assert_equal 'quota_exceeded', body['error']
    assert_operator last_response.headers['Retry-After'].to_i, :>=, 1
  end

  def test_global_budget_returns_429
    @overrides = { 'GLOBAL_ENGINE_SEC_PER_MIN' => '1' }
    app
    @service.instance_variable_get(:@budget).charge(2)
    body = analyze({ fen: START_FEN })

    assert_equal 429, last_response.status
    assert_equal 'busy', body['error']
  end

  def test_requires_json_content_type
    header 'Authorization', "Bearer #{TOKEN}"
    post '/v1/analyze', { fen: START_FEN }.to_json, 'CONTENT_TYPE' => 'application/x-www-form-urlencoded'

    assert_equal 415, last_response.status
  end

  def test_healthz_needs_no_token
    get '/healthz'
    body = JSON.parse(last_response.body)

    assert_equal 200, last_response.status
    assert_equal 'ok', body['status']
    assert_equal 2, body['workers'].size
  end

  def test_unknown_route_is_json_404
    get '/v1/nope'

    assert_equal 401, last_response.status
    header 'Authorization', "Bearer #{TOKEN}"
    get '/v1/nope'

    assert_equal 404, last_response.status
  end
end
