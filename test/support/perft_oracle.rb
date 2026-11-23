# frozen_string_literal: true

require_relative 'engine_server'

# Stockfish as a chess rules oracle, for positions ChessModel cannot judge
# (those with castling rights). "go perft 1" lists exactly the legal moves of
# a position, and "d" prints the FEN after a list of moves and whether the
# side to move is in check. Only feed it positions known to be legal:
# Stockfish assumes they are.
class PerftOracle
  MOVE_LINE = /\A(?<move>[a-h][1-8][a-h][1-8][qrbn]?): \d+\z/
  TIMEOUT_S = 10

  # A position judged by the oracle. It answers the ChessModel::Position
  # calls the property tests make (to_fen, legal_moves, play, checkmate?), so
  # it can stand in for one in an EdgeCaseScenario.
  class Position
    attr_reader :oracle, :fen

    def initialize(oracle, fen)
      @oracle = oracle
      @fen = fen
    end

    def to_fen = @fen
    alias to_s to_fen
    alias inspect to_fen

    def ==(other)
      other.is_a?(Position) && fen == other.fen
    end

    def legal_moves = @oracle.describe(@fen)[:legal_moves]
    def in_check? = @oracle.describe(@fen)[:in_check]
    def checkmate? = legal_moves.empty? && in_check?

    # Stockfish skips an illegal move without a word, so this refuses one.
    def play(move)
      raise ArgumentError, "#{move} is not legal in #{@fen}" unless legal_moves.include?(move)

      @oracle.position(@oracle.describe(@fen, [move])[:fen])
    end
  end

  def self.shared
    @shared ||= new(EngineServer::ENGINE).tap { |oracle| Minitest.after_run { oracle.stop } }
  end

  def initialize(engine)
    @process = StockfishPool::UciProcess.new([engine])
    @mutex = Mutex.new
    @cache = {}
    exchange('uci', 'uciok')
  end

  def position(fen)
    Position.new(self, fen)
  end

  # { fen:, legal_moves:, in_check: } for +fen+ after +moves+, with the FEN as
  # Stockfish writes it and the legal moves sorted.
  def describe(fen, moves = [])
    key = [fen, moves].freeze
    @mutex.synchronize { @cache[key] ||= query(fen, moves) }
  end

  def stop
    @process.quit
  end

  private

  def query(fen, moves)
    @process.write_line(moves.empty? ? "position fen #{fen}" : "position fen #{fen} moves #{moves.join(' ')}")
    perft = exchange('go perft 1', 'Nodes searched')
    board = exchange('d', 'Checkers:')
    {
      fen: board.find { |line| line.start_with?('Fen: ') }.delete_prefix('Fen: '),
      legal_moves: perft.filter_map { |line| MOVE_LINE.match(line)&.[](:move) }.sort.freeze,
      in_check: !board.last.delete_prefix('Checkers:').strip.empty?
    }.freeze
  end

  def exchange(command, reply)
    lines = []
    @process.write_line(command)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_S
    return lines if @process.read_until(reply, deadline, lines)

    raise "Stockfish sent no #{reply.inspect} after #{command.inspect}"
  end
end
