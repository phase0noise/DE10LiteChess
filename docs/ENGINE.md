# Expanded DE10-Lite chess engine

The engine expands normal lookahead from three to six plies and
uses the MAX 10's block RAM for search rather than replicating whole chess
engines. The FPGA still chooses every computer move. The Pico serves the page
and forwards UART commands; the browser checks legality independently.

## Search

The earlier October 24 release (`8e713ca`) uses the wired reach map to skip impossible
destinations, adding pawn pushes and castling squares before the existing legal
filter. Deterministic three-ply fork/promotion comparisons preserve all 18 root
scores, both selected moves, node counts and cache matches while reducing
decision cycles from 4,503,888 to 3,582,792 (**20.45%**). This compares the same
cached engine with fast scanning enabled/disabled, not different search depths.
See [destination-results.json](destination-results.json). The production generic
`FAST_DESTINATIONS` defaults to true; false retains the original walk for tests.

## Datapath parallelism

Three additional changes reduce work repeated throughout the search tree:

- The board stack packs eight squares into a 32-bit word. A restore copies
  eight squares per RAM read/copy pair, reducing 128 controller enables to 16
  (10.24 to 1.28 microseconds at the current clock/enable).
- A parallel 64-bit source-eligibility mask lets move generation select the
  next occupied friendly square directly. Source ordering stays ascending.
- Two pawn-file arithmetic lanes evaluate independent files together, reducing
  the eight-file pass to four controller enables. Each file's weighting and
  signed rounding occur before its contribution is added to the total.

The shared spatial fabric and search controller remain single instances. The
stack still stores 3,072 logical bits, and RAM read latency is unchanged. The
save pass packs eight squares per write while material evaluation and hashing
continue to scan individual squares. These features default to
`STACK_LANES=8`, `FAST_SOURCES=true` and `PAWN_LANES=2`. Setting them to
`1`, `false` and `1` recreates the preceding datapath for comparison.

See [PARALLEL_ARCHITECTURE.md](PARALLEL_ARCHITECTURE.md) for the stage diagram
and the planned four-lane material/placement evaluator and banked hash ROM.

On the deterministic three-ply fork/promotion pair, total decision cycles fall
from **3,582,792** in the preceding datapath to **1,533,784**: **57.19% fewer
cycles**, or **2.336x throughput**, at the same 50 MHz clock. The reference and
parallel variants have the same 18 candidate scores, selected moves, nodes and
cache matches. Random root preferences and field relaxation are disabled in
this comparison. See [parallel-results.json](parallel-results.json).

## Search policy

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
| Board stack | 12 x 8 x 32 bits | Eight-square words; one speculative board per level |
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

The release fits in 30,949 logic elements (62%) and 917,128 memory bits (55%),
occupying 125 of the 182 M9K blocks (69%) after RAM width/depth packing.
Setup, hold, recovery and removal timing pass at every available operating
corner with a 50 MHz board clock. Engine state advances on its existing
four-cycle enable; UART and RAM ports operate at the native clock. See
build-results.txt for exact slack and firmware measurements.
The standalone engine generic also defaults to four and rejects a smaller
divider, which would violate the synchronous RAM pipeline and SDC assumptions.

The host explanation-byte decoder uses bounded comparisons for its four
18-byte records in place of general division/modulo. Its RAM read latency is
unchanged. The parallel-datapath build passes setup with **2.093 ns** slack at the
slow 85 C corner and hold with **0.071 ns** at the fast corner, with no
unconstrained clocks or external ports.

## Browser console and game modes

The console polls existing status and command-18 telemetry while searching,
then reads the recurrent field and selected candidate explanation before
commit. It displays FPGA counters, the strongest five candidates and the seven
score components. Field colors show the last completed snapshot, fixed with
White at bottom. Scores are raw preferences, not a calibrated evaluation.

Self-play sends both sides through the same hardware path. Speed-round expiry
sends the human side through Spatial mode and reapplies normal settings for
the opponent's reply. Pass-and-play does not request engine evaluations.
Mode, color and human timer settings apply on New game. Speed/self-play restore
paused, and timeout handling cancels any open human promotion choice.

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
