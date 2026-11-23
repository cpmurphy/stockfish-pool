# frozen_string_literal: true

require_relative 'edge_case_generators'
require_relative 'perft_oracle'

# Castling scenarios, judged by Stockfish's perft (PerftOracle) because
# ChessModel does not model castling. Each one is an EdgeCaseScenario whose
# positions are PerftOracle::Positions. Every scenario is built for White and
# mirrored for Black. White's king and the rook of +wing+ are on their home
# squares with the right to castle there, and a twist says what happens:
#
# - legal:         castling is legal; the line is a black move, the castle and a reply.
# - quiet_attack:  also legal, though Black attacks the rook's square or b1
#                  (squares the king does not cross).
# - blocked:       a piece stands between the king and the rook.
# - through_check: Black attacks a square the king crosses.
# - in_check:      Black's last move gives check.
# - king_moved:    the king steps away and back, so the right is gone.
# - rook_moved:    the rook moves away and back, so the right is gone.
# - rook_captured: Black takes the rook on its home square and another white
#                  rook takes back there, so the right is gone.
#
# In the last three, castling would be legal if the right were restored; the
# right is the only thing in the way. The builders are deterministic for
# their arguments (Stockfish's perft is too), so a failure can be rebuilt
# from what its report prints.
module CastlingCases
  G = PropCheck::Generators

  KING = [4, 0].freeze
  WINGS = {
    king: { right: 'K', rook: [7, 0], to: [6, 0], empty: [[5, 0], [6, 0]], crossed: [[5, 0], [6, 0]],
            unguarded: [[7, 0]], raiders: [[6, 2], [5, 1]] },
    queen: { right: 'Q', rook: [0, 0], to: [2, 0], empty: [[1, 0], [2, 0], [3, 0]], crossed: [[3, 0], [2, 0]],
             unguarded: [[0, 0], [1, 0]], raiders: [[1, 2]] }
  }.freeze
  # Castling right => [king square, king, rook square, rook].
  HOMES = {
    'K' => [[4, 0], 'K', [7, 0], 'R'], 'Q' => [[4, 0], 'K', [0, 0], 'R'],
    'k' => [[4, 7], 'k', [7, 7], 'r'], 'q' => [[4, 7], 'k', [0, 7], 'r']
  }.freeze
  LEGAL_TWISTS = %i[legal quiet_attack].freeze
  ATTACK_TWISTS = %i[quiet_attack through_check in_check].freeze
  RETURN_TWISTS = %i[king_moved rook_moved].freeze
  TWISTS = (LEGAL_TWISTS + %i[blocked through_check in_check] + RETURN_TWISTS + %i[rook_captured]).freeze
  COMBINATIONS = EdgeCases::COLORS.product(WINGS.keys, TWISTS).map do |color, wing, twist|
    { color: color, wing: wing, twist: twist }
  end.freeze

  module_function

  def castling(oracle, color:, wing:, twist:, seed:)
    params = { color: color, wing: wing, twist: twist, seed: seed }
    start, moves = EdgeCases.attempt(seed, 2_000) { |rng| build(oracle, WINGS.fetch(wing), twist, rng) }
    start, moves = flip(start, moves) if color == 'b'
    positions = moves.each_with_object([oracle.position(start)]) { |move, acc| acc << acc.last.play(move) }
    EdgeCaseScenario.new(kind: :castling, params: params, positions: positions, moves: moves, forbidden: nil)
  end

  def castling_case(oracle)
    G.tuple(EdgeCases.element(COMBINATIONS), EdgeCases.seed).map do |combination, s|
      castling(oracle, **combination, seed: s)
    end
  end

  # Castling-shaped moves for the side to move: both castles, and the king
  # taking its own rook (how Chess960 writes castling, which is not legal here).
  def candidates(position)
    rank = position.to_fen.split[1] == 'w' ? '1' : '8'
    %w[g c h a].map { |file| "e#{rank}#{file}#{rank}" }
  end

  # --- Builders, for White. Each returns [start FEN, moves] or nil to retry. ---

  def build(oracle, wing, twist, rng)
    board = home_board(wing, rng)
    if RETURN_TWISTS.include?(twist)
      return_trip(oracle, board, wing, twist == :king_moved ? KING : wing[:rook], rng)
    elsif twist == :rook_captured
      capture_and_replace(oracle, board, wing, rng)
    else
      one_move_before(oracle, board, wing, twist, rng)
    end
  end

  # White's king and the rook of +wing+ at home, sometimes the other rook and
  # Black's king and rooks too, and a few other pieces (none in the way).
  def home_board(wing, rng)
    board = { KING => 'K', wing[:rook] => 'R' }
    board[([[0, 0], [7, 0]] - [wing[:rook]]).first] = 'R' if rng.rand < 0.5
    if rng.rand < 0.5
      board[[4, 7]] = 'k'
      [[0, 7], [7, 7]].each { |square| board[square] = 'r' if rng.rand < 0.5 }
    else
      EdgeCases.place(board, rng, 'k', EdgeCases::ALL_SQUARES.select { |square| EdgeCases.distance(square, KING) > 1 })
    end
    EdgeCases.add_extras(board, rng, rng.rand(0..4), EdgeCases::ALL_SQUARES - wing[:empty])
    board
  end

  # The twist arranged on a board with White to move, then a quiet black move
  # that led to it.
  def one_move_before(oracle, board, wing, twist, rng)
    return unless arrange(board, wing, twist, rng)

    before, prior = EdgeCases.unmove(board, 'b', rng)
    return unless before

    start = oracle.position(with_rights(before.to_fen, before.board, wing, rng))
    return unless start.legal_moves.include?(prior)

    after = start.play(prior)
    special = castle(wing)
    legal = after.legal_moves.include?(special)
    return unless legal == LEGAL_TWISTS.include?(twist)
    return [start.fen, [prior]] unless legal

    [start.fen, [prior, special, after.play(special).legal_moves.sample(random: rng)].compact]
  end

  # Sets up the twist, and checks it is the only thing that could stop the
  # castle: exactly the squares it attacks among the king's square and the
  # squares it crosses are attacked (so a check that also covers f1 does not
  # count as an in_check case).
  def arrange(board, wing, twist, rng)
    target = attack_target(wing, twist, rng)
    placed = case twist
             when :blocked then EdgeCases.place(board, rng, %w[N B R Q n b r q].sample(random: rng), wing[:empty])
             when *ATTACK_TWISTS then place_attacker(board, rng, target, wing)
             else true
             end
    probe = ChessModel::Position.new(board, side: 'w')
    attacked = ([KING] + wing[:crossed]).select { |square| probe.attacked?(square, 'b') }
    placed && attacked == ([target] & ([KING] + wing[:crossed]))
  end

  def attack_target(wing, twist, rng)
    case twist
    when :quiet_attack then wing[:unguarded].sample(random: rng)
    when :through_check then wing[:crossed].sample(random: rng)
    when :in_check then KING
    end
  end

  # Adds a black piece, out of the castling path, that attacks +target+.
  def place_attacker(board, rng, target, wing)
    free = EdgeCases::ALL_SQUARES - board.keys - wing[:empty]
    options = free.product(EdgeCases::ATTACKER_TYPES.uniq).select do |square, type|
      next false if type == 'p' && [0, 7].include?(square[1])

      ChessModel::Position.new(board.merge(square => type), side: 'w').attacks_from(square).include?(target)
    end
    square, type = options.sample(random: rng)
    board[square] = type if square
  end

  # White moves +piece_square+'s piece away and back, Black replying each time.
  def return_trip(oracle, board, wing, piece_square, rng)
    model = EdgeCases.position(board, 'w', rng)
    return unless model.well_formed?

    start = oracle.position(with_rights(model.to_fen, board, wing, rng))
    from = ChessModel.square_name(piece_square)
    away = start.legal_moves.select { |move| move.start_with?(from) && !castles.include?(move) }.sample(random: rng)
    return unless away

    line_from(start, [away, :reply, away[2, 2] + away[0, 2], :reply], rng, wing)
  end

  # Black takes the rook at home with a knight; another white rook, further up
  # the file, takes back on the rook's home square.
  def capture_and_replace(oracle, board, wing, rng)
    raider = (wing[:raiders] - board.keys).sample(random: rng)
    replacement = [wing[:rook][0], rng.rand(2..6)]
    return if raider.nil? || board.key?(replacement)

    board[raider] = 'n'
    board[replacement] = 'R'
    model = EdgeCases.position(board, 'b', rng)
    return unless model.well_formed?

    start = oracle.position(with_rights(model.to_fen, board, wing, rng))
    line_from(start, [EdgeCases.uci(raider, wing[:rook]), EdgeCases.uci(replacement, wing[:rook]), :reply], rng, wing)
  end

  # Plays +plan+ from +start+ (:reply is a random legal move) and keeps the line
  # if it ends with the castling right of +wing+ the only thing in the way.
  def line_from(start, plan, rng, wing)
    moves = []
    final = plan.reduce(start) do |position, step|
      move = step == :reply ? position.legal_moves.sample(random: rng) : step
      return nil unless move && position.legal_moves.include?(move)

      moves << move
      position.play(move)
    end
    [start.fen, moves] if only_the_right_is_missing?(final, wing)
  end

  def only_the_right_is_missing?(position, wing)
    special = castle(wing)
    board = ChessModel::Position.from_fen(position.fen).board
    return false if position.legal_moves.include?(special) || board[KING] != 'K' || board[wing[:rook]] != 'R'

    fields = position.fen.split
    fields[2] = normalized_rights(fields[2] + wing[:right])
    position.oracle.position(fields.join(' ')).legal_moves.include?(special)
  end

  # --- Helpers ---

  def castle(wing)
    EdgeCases.uci(KING, wing[:to])
  end

  def castles
    WINGS.values.map { |wing| castle(wing) }
  end

  # +fen+ with the castling right of +wing+ and, at random, the other rights
  # +board+ allows.
  def with_rights(fen, board, wing, rng)
    rights = HOMES.select do |right, (king_square, king, rook_square, rook)|
      board[king_square] == king && board[rook_square] == rook && (right == wing[:right] || rng.rand < 0.5)
    end
    fields = fen.split
    fields[2] = normalized_rights(rights.keys.join)
    fields.join(' ')
  end

  def normalized_rights(rights)
    letters = 'KQkq'.chars.select { |letter| rights.include?(letter) }.join
    letters.empty? ? '-' : letters
  end

  def flip(fen, moves)
    fields = ChessModel::Position.from_fen(fen).flip.to_fen.split
    fields[2] = normalized_rights(fen.split[2].swapcase)
    [fields.join(' '), moves.map { |move| ChessModel.flip_move(move) }]
  end
end
