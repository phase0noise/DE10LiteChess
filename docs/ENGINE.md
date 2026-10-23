# Expanded DE10-Lite chess engine

The October 22 engine expands normal lookahead from three to six plies and
uses the MAX 10's block RAM for search rather than replicating whole chess
engines. The FPGA still chooses every computer move. The Pico serves the page
and forwards UART commands; the browser checks legality independently.

## Search

The default targets five normal plies with a ten-second budget. Iterative
deepening completes depths 2, 3, 4, 5, then 6 if requested. Every root move
receives a full-window alpha-beta search, preserving a scored, complete legal
set for the host's verification. The deepest completed iteration supplies the
move; an unfinished iteration never supplies a partially scored result.

Each node generates its pseudo-legal moves into a RAM queue. Search ordering
prefers a matching cache move, captures and promotions, two killer moves per
ply, then quiet-move history and piece placement. Every applied move passes
the existing spatial king-safety filter. Castling, en passant, all four
promotions, rights, turn and king squares are saved/restored through the same
speculative-board mechanism used for ordinary legal moves.

Quiescence searches captures and promotions for up to four further plies and
searches all check evasions. One additional evasion ply is allowed at the
quiescence limit. Stand pat and horizon evaluation first establish that a
legal move exists, so checkmate and stalemate remain visible at the frontier.
Terminal mate scores favor shorter wins and longer survival. Bare kings,
king and a single minor against king, and bishop-only positions with bishops
all on one color score as insufficient-material draws. Repeated positions on
the current speculative path score as draws; the browser retains full game
history and applies the game-level repetition and move-count rules.

## Block RAM

| Table | Logical capacity | Purpose |
| --- | --- | --- |
| Position cache | 4,096 x 128 bits | Position key, depth, score, bound, move, epoch |
| Ordered moves | 12 x 512 x 32 bits | Moves and ordering priorities for each stack level |
| Quiet history | 4,096 x 13 bits | Saturating source/destination cutoff history |
| Zobrist keys | 1,024 x 64 bits | Piece/color/square hash ROM |
| Board stack | 12 x 64 x 4 bits | One serialized speculative board per level |
| Candidate results | 2 x 256 x 144 bits | Published and in-progress root explanations |

The cache compares the full 64-bit key, including pieces, side to move,
castling rights and en-passant square. Entries record normal depth, remaining
quiescence allowance, stack allowance, exact/lower/upper score bound and mate
distance. A new evaluation advances an epoch, preventing results from a
different root or policy configuration from being reused. Soft reset preserves
the epoch because it does not clear RAM; epoch wrap clears the cache before
starting again. Search-path repetition results are not cached through their
ancestors. A 64-bit hash still has a finite collision probability.

All tables use synchronous M9K ports. Initialized cache/history RAM and the key
ROM require the MAX 10 configuration setting `SINGLE COMP IMAGE WITH ERAM`,
which is included in the QSF. No RAM is cleared through a large reset mux.

## Evaluation

Each searched position is evaluated from its board contents, avoiding
path-dependent rounding in cached scores. Material and piece placement blend
between middlegame and endgame according to the remaining minor/rook/queen
material. Additional terms reward bishop pairs, passed pawns, rook files and
king pawn shelter, and penalize isolated/doubled pawns and exposed king files.
The root retains bounded recurrent-field and move-history preferences. Mate
scores override those preferences so they cannot outweigh a forced mate.

The release fits in 29,371 logic elements (59%) and 917,128 memory bits (55%),
occupying 125 of the 182 M9K blocks (69%) after RAM width/depth packing.
Setup, hold, recovery and removal timing pass at every available operating
corner with a 50 MHz board clock. Engine state advances on its existing
four-cycle enable; UART and RAM ports operate at the native clock. See
build-results.txt for exact slack and firmware measurements.
The standalone engine generic also defaults to four and rejects a smaller
divider, which would violate the synchronous RAM pipeline and SDC assumptions.

## Reproduce checks

`tools/verify.ps1` checks the production wired legality fabric, RAM, UART,
browser rules, existing tactical fixtures, cache enabled/disabled comparisons,
and safe budget expiry. Add `-Browser` for Chrome interaction checks or
`-Strength` for the longer mate-in-three benchmark. The independent oracle
enumerates every defender reply with python-chess and proves each fixture
requires five plies. This is a focused tactical benchmark, not an Elo rating.

Long search simulations use `sim/chess_spatial_fast.vhd` to compute the same
attack/reach planes more efficiently in software. A dedicated test compares
both architectures on all 64 source squares in every independent rule fixture
before using the model. Production QSF files always select the wired fabric;
the controller, RAM and evaluator in search simulations are the production RTL.
