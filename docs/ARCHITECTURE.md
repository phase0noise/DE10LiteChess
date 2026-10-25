# How the chess machine works

The system has three jobs: run a chess game, connect a phone to the board, and
choose a move. The browser, Pico W and FPGA each handle one of those jobs.

## The three parts

| Part | Responsibilities | Main source |
| --- | --- | --- |
| Browser | Board and gestures, independent chess rules, SAN/PGN, game history, captures, draws, game modes, human clock and engine display | `web/chess.js`, `web/app.js`, `web/style.css` |
| Browser transport | Queue commands, upload positions/settings, poll counters, compare legal sets and board readbacks, request the selected move's guarded commit | `web/fpga.js` |
| Pico W | Host `FPGA-Chess` Wi-Fi, serve the embedded page, bridge HTTP to framed UART, retry packets | `firmware/pico_chess/pico_chess.ino`, `chess_protocol.h` |
| FPGA endpoint | Validate framing and CRC, handle retries, snapshot replies while evaluation continues | `rtl/chess_uart_bridge.vhd`, `uart_rx.v`, `uart_tx.v` |
| FPGA engine | Legal move generation, speculative moves, evaluation, search, recurrent field, move selection and telemetry | `rtl/chess_engine.vhd` |
| Spatial fabric | Concurrent White attacks, Black attacks and selected-source reachability | `rtl/chess_spatial.vhd` |
| FPGA memory | Search tables and recurrent cell/policy storage in M9K RAM | `rtl/chess_search_memory.vhd`, `chess_cell_memory.vhd` |
| Exchange analyzer | Bounded least-attacker swap-off analysis for capture ordering | `rtl/chess_see.vhd` |
| Board wrapper | PLL from the 50 MHz reference, reset/key synchronization, UART pins, LEDs and seven-segment display | `rtl/de10_chess.vhd`, `chess_clock.vhd` |

No internet server is involved during play. The page, scripts and piece artwork
are embedded in Pico flash by `web/embed_web.ps1`. The phone sends compact chess
commands; it does not stream the board display over UART.

## What happens after you play e4

The browser first checks that e2-e4 is legal and records the move. For the
FPGA's Black turn it uploads all 64 squares plus side to move, castling rights
and en-passant square. This position is the FPGA's factual board.

The engine builds its attack maps and recurrent field. For every possible
reply it temporarily changes a speculative board and checks whether Black's
king is attacked. It also handles rook movement when castling, the pawn removed
by en passant and all four promotion choices.

At the default settings, it completes a two-ply search, then tries three, four
and five plies. A ply is one move by one side. With five plies, the tree includes
Black's reply, White's response, Black's next move, White's next response and
Black's next move. Capture extensions examine tactical continuations further.

The next iteration writes into a different candidate-results RAM bank. If the
ten-second budget expires, the previous complete bank stays available. The
first iteration is allowed to finish even if it exceeds that budget, so the
browser always receives a complete legal set.

The browser compares the hardware's entire legal set with its own rules,
checks that the loaded position still matches, and obtains the selected move's
explanation and legally replayed continuation. It then commits that exact move with a generation number. The
FPGA rejects an obsolete generation or a different move. Finally the browser
reads back the resulting board and updates the display.

## What is parallel, and what is shared

The spatial fabric has a cell for each square and three wired planes. Sliding
piece rays travel through empty cells and stop at occupied cells. Knights,
kings and pawn attacks use fixed local connections. These connections evaluate
concurrently; there is no software loop tracing each ray on the Pico.

The search controller is a state machine. It explores one branch at a time,
saving and restoring boards in RAM. Alpha-beta allows it to stop a branch once
the branch cannot improve the decision. Move ordering tries cache hints,
captures, promotions, killer moves and useful quiet moves early, making those
cutoffs more likely.

The board stack now moves eight squares per 32-bit word. Restoring a branch
takes 16 controller enables rather than 128. A parallel source mask skips
ineligible source squares, and two pawn-file arithmetic lanes halve the
eight-file evaluation pass. These changes speed work repeated at each node.
Four material/placement lanes and four matching hash-ROM banks process four
squares per enable. Registered pair sums replace a long serial arithmetic
chain. Four interleaved move-RAM banks feed pair and group comparators, so move
selection also consumes four entries together. These are repeated operations
inside one search, rather than separate engines playing independent games.

The recurrent field contains 64 signed cell values. Shared arithmetic updates
them using neighboring values, attack information, configured weights, local
bias and pseudorandom input. This is a programmable recurrent circuit, not a
trained neural network. Spatial mode uses its root preference calculation
without exploring the search tree. Search mode now uses consistent positional
values without adding field, habit or random bonuses to the searched result.
The console can still display the completed field snapshot in either mode.

This division keeps the design within the MAX 10: parallel square-level
geometry, a shared search/evaluation controller, and RAM for state. The native
clock comes from a PLL driven by the 50 MHz oscillator; the controller's common
enable occurs every four internal clocks. UART, exchange analysis and memory
ports use native clocks. Registered requests separate long controller decoding
from short write/start strobes. The reported clock drives host time conversion
and FPGA budgets. See [build-results.txt](build-results.txt) for the qualified
frequency and [ADVANCED_ENGINE.md](ADVANCED_ENGINE.md) for the timing contract.

## Memory and reuse

The 4,096-entry position cache stores a full 64-bit position key, search depth,
score bound, preferred move and validity epoch. A cache match can supply an
answer when the stored search is deep enough, or a move-ordering hint otherwise.
The key includes side to move, castling rights and en passant. Mate distances,
quiescence allowance and stack allowance also participate in reuse decisions.
An evaluation changes the epoch, so the cache reuses positions within that
evaluation rather than carrying scored results across unrelated turns.

Other RAM holds 14 board-stack levels, 14 move queues, quiet-move history,
Zobrist hashing constants, continuation prefixes and two root-result banks.
See [ENGINE.md](ENGINE.md)
for capacities, bounds and draw handling.

## The destination-scan improvement

Previously, an eligible source visited every destination square, alternating
`PICK` and `ADVANCE`, even when its reach map already ruled most of them out.
The new scanner finds the next set bit after the current destination. Pawn
pushes and castling destinations are added because attack maps do not include
those moves. The existing checks still decide whether each candidate is legal.

Destinations remain in ascending square order, and promotions still visit all
four choices. Deterministic comparisons can therefore check every root score,
selected move, node count and cache-match count against the original scanner.
`FAST_DESTINATIONS=false` selects the original walk for that comparison; the
production generic defaults to the reach-map scanner.

Explanation reads also use bounded comparisons for the four 18-byte records
in a reply. This avoids synthesizing a general division/modulo network into
the native-clock byte decoder and preserves the existing RAM read latency.

## Reading the engine console

| Display | Meaning |
| --- | --- |
| Pipeline strip | Host-observed upload, field/search polling, verification and commit stages |
| FPGA decision time | 48-bit cycle counter divided by the device-reported frequency; includes field setup and all search iterations |
| Nodes | Visited search nodes, including earlier iterations and capture extensions |
| Completed depth | Last fully published iteration; a larger requested depth may remain unfinished |
| Nodes / FPGA second | Nodes divided by FPGA decision time; excludes HTTP verification/commit time |
| Alpha-beta cutoffs | Branches stopped by the alpha-beta search |
| Matching cache probes | Full-key matches, including hints that could not directly supply a score |
| Cache writes | Entries stored during the evaluation |
| Search trace | Cumulative node samples over the FPGA cycle counter; not a waveform or logic analyzer |
| Spatial heatmap | Last completed field snapshot; orientation remains White at bottom when the main board flips |
| Phase profile | Seven measured groups whose cycle counts sum to snapshot decision time |
| Clock / lanes / visited ply | Actual device frequency, evaluator width and deepest visited tactical level |
| Candidate score | Exact searched value or explicitly labeled score bound; Spatial mode uses preferences |
| Continuation | Legally checked captured principal-variation prefix; cache cutoffs can shorten it |
| Chosen move breakdown | Seven root components; search mode uses the searched value, with immediate-root king/mobility terms shown separately |
| Cache answers / root re-searches / exchange calls | Cache cutoffs, full-window retries after promising scouts and capture-ordering analysis |

Status is polled around every 120 ms, with search telemetry sampled around
every 500 ms. UART and HTTP add latency. The final board and explanations are
read before commit; the completed field is not presented as a live simulation.
The counters are snapshots of an evolving engine, so live rates are approximate.

## Game modes

Self-play uses this same command path twice per full move. There are no extra
engines instantiated. Pass-and-play uses the browser rules and requires no
FPGA searches.

The speed clock belongs to the browser. On expiry, it cancels an open promotion
dialog and requests a Spatial move from the FPGA for the human side. That move
gets the same legal-set verification and guarded commit as an ordinary reply.
The next opponent turn reapplies the selected search depth and time budget.
The timer is paused while the FPGA works; the next human clock starts after
the reply is verified. Reload restores speed/self-play paused. A backgrounded
browser can delay a timeout callback until the page runs again.

## How the search changes help

The previous completed best move is searched first at the next depth. Later
root moves get a narrow scout window; only a move that might improve the best
value needs a full-window re-search. Losing scouts are published as upper
bounds, while the selected winner must be exact. This reduces unnecessary
nodes without discarding the complete legal root set.

King-zone pressure and weighted per-piece mobility improve the information
available at the horizon. Exchange analysis orders ambiguous defended
captures, including newly exposed slider rays; it never prunes a move.
Eight-ply normal search and four capture extensions can spend the hardware
speed gain on longer continuations when the time budget permits. Requested
depth does not promise that every position will finish that depth.

[ADVANCED_ENGINE.md](ADVANCED_ENGINE.md) describes the implemented pipeline.
Controlled comparisons establish cycle savings and valid score bounds;
equal-time games are still needed to measure playing strength.
