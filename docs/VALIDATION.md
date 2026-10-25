# Engine advancement validation - October 24, 2026

The current engine combines eight-ply capability, root ordering/PVS, four
material/hash lanes, four move-queue banks, positional terms, capture exchange
ordering, measured phase telemetry and a PLL clock. [ADVANCED_ENGINE.md](ADVANCED_ENGINE.md)
describes the implemented datapath. [build-results.txt](build-results.txt)
records the qualified image's frequency, resources and all-corner slack.

The FPGA build passes all timing gates at **75 MHz**, using 39,982 logic
elements (80%) and 133 M9Ks (73%). Worst setup is **+2.293 ns**; minimum hold
is **+0.113 ns**. The PLL increases the internal clock by 50% from the original
50 MHz design. Physical-board acceptance remains separate below.

## Functional checks

The core checks completed with eight generated game positions supplementing
nineteen explicit rule positions, for 27 independent root fixtures. The run
used `tools/verify.ps1 -Positions 8 -Browser -Strength`; its optional long mate
benchmark was stopped after two completed cases at the user's request, before
the final browser step. This is not a claim that the entire command completed.
Completed core checks cover:

- Browser rules and wired RTL legal/attack sets against python-chess, including
  castling, en passant, pinned pieces, all promotions, mate/stalemate and draws.
  The simulation-only attack model agrees with the wired fabric on all 64
  source squares of those positions before it is used for long searches.
- Ten three-ply tactical fixtures on both colors, including mate over material,
  poisoned capture, royal forks, an en-passant reply and promotion. Selected
  moves undergo commit/readback and stale-generation rejection.
- Cache enabled/disabled, narrow/wide stack, source scan and pawn-file
  comparisons. Datapath comparisons preserve candidate values, selected moves,
  node counts and cache matches; search-order comparisons validate exact best
  values and bounds instead of requiring identical node counts.
- Four evaluation lanes against one lane; root PVS against a full-window
  reference; four queue banks against one queue entry at a time. The controlled
  fork/promotion comparison disables new positional terms and exchange ordering
  to isolate these changes. Nineteen special-rule searches also compare
  full-window values with PVS bounds while those features are enabled.
- Independent replay of captured continuation prefixes. The selected root value
  must be exact, with matching completed-depth metadata; losing scouts are
  checked as valid upper bounds. Seven 48-bit phase counters sum to the
  coherent decision-cycle snapshot.
- Budget expiry before the first iteration completes and during a later one.
  The published legal set, explanations, selected value and guarded promotion
  commit remain complete. The test clock is scaled to exercise deadlines;
  board time uses the reported PLL frequency.
- Completed depth eight on both forced-draw fixtures and a live pawn ending
  (`8/8/8/8/8/2k5/P7/K7 w - - 0 1`) that actually visits at least eight plies.
  This tests real stack traversal rather than only terminal positions.
- All fourteen move-queue levels and four banks, cache/history endpoints and
  all 1,024 banked Zobrist keys against the scalar key port.
- The actual reciprocal helper against integer division: both range limits,
  all residue classes and deterministic samples across its 21-bit input range.
  Signed score comparisons cover both colors. All eighteen Spatial candidate
  scores, including the recurrent field and native-time noise, agree before
  and after the timing pipeline changes.
- Exchange analysis for poisoned captures, x-ray recaptures, both colors,
  en passant, promotion, defended king recapture and cancellation. Read,
  arithmetic and write stages use native clocks.
- Native UART framing/CRC, malformed/partial/oversize requests, retry tokens,
  policy validation/readback, protocol-5 status/telemetry and guarded commit.
  The actual Pico C++ parser passes corruption, resynchronization and frame
  sizes through 1,024 reply bytes.
- Browser protocol 3/4 compatibility, protocol-5 capabilities/bounds, legal
  continuation checks, 48-bit counters beyond 2^32, clock conversion, unknown
  version rejection and failure before commit on inconsistent device data.

An earlier Chrome desktop and 390 px touch run passed gestures, themes,
promotions, captures/points/material, console phase profile/bounds/continuation,
offline pass-and-play, self-play pause/resume, undo/reload and Spatial auto-play
on speed-round expiry, including an open promotion dialog. It used an explicitly
simulated endpoint before the final 48-bit wire-layout changes. The final
protocol changes passed the Node checks listed above; a fresh full browser run
was not performed. These establish client behavior separately from physical
FPGA/Wi-Fi operation. Tools are GHDL 6.0.0, python-chess 1.11.2, Node.js 22.18.0,
GCC 7.4.0 and Chrome.

## Measurements and their scope

[advancement-results.json](advancement-results.json) records scalar, lane,
root-PVS and queue comparisons, exact values, valid bounds and legally replayed
prefixes. Its cycle totals describe the stated deterministic fixtures and
settings, rather than whole-game throughput or an Elo gain. Native-clock
pipeline fixes trade a few extra arithmetic enables and exchange clocks for
shorter paths; fitted frequency and total cycles must be considered together.

| Controlled configuration | Decision cycles | Search nodes |
| --- | ---: | ---: |
| One evaluation lane, full root windows, scalar queue | 1,573,992 | 1,436 |
| Four evaluation/hash lanes | 1,298,280 | 1,436 |
| Plus root ordering and PVS | 345,508 | 488 |
| Plus four-bank move selection | 276,828 | 488 |

That is 82.4% fewer cycles (5.69x) for these two fixtures. Lane widening
preserves every exact candidate score; PVS preserves the best value and
publishes valid bounds. Queue banking preserves the PVS choices, bounds and
node counts. Against the pre-pipeline arithmetic, each configuration keeps
its scores/nodes and adds exactly sixteen clocks per evaluated node. The
separate Spatial comparison also preserves its eighteen scores with field
and native-time noise enabled.

The five-ply mate regression independently proves all winning first moves by
enumerating every defender reply. Quiescence is disabled to isolate normal
lookahead. [advanced-strength-results.json](advanced-strength-results.json)
records the two completed cases out of twelve, one for each color; both chose
an independently proven winning move. The remaining optional cases were not
completed. The historical [strength-results.json](history/strength-results.json)
records an October 22 baseline of 12/12 for the then-expanded engine versus
2/12 for its three-ply predecessor. No paired-game Elo or equal-time win-rate
measurement has been performed.

Historical [parallel-results.json](history/parallel-results.json) retains the first
50 MHz parallel release's 3,582,792 to 1,533,784 cycle reduction on two fixtures
(2.336x). [destination-results.json](history/destination-results.json) retains its older
20.45% destination-scan reduction. Those records use earlier evaluators and
workloads; they are not current timing/resource figures, and their speedups
should not be multiplied into the new comparison.

## Builds and distribution

Quartus Prime Lite 23.1std.1 targets the actual 10M50DAF484C7G. The build script
uses an isolated source snapshot and checks setup, hold, recovery and removal
at every available operating condition, plus unconstrained clocks and external
ports. It exports global, native-source and native-endpoint critical paths.
Only a passing build whose input hashes still match the source is copied to
`output_files`; failed candidates stay in `.cache`.

The Pico W image uses Arduino-Pico 6.0.0 at 133 MHz: 506,292 program bytes
(24%) and 76,408 global RAM bytes (29%). Page, scripts and artwork are embedded
in flash, with no CDN requests. The matching protocol-5 FPGA and Pico images
must be loaded together. `build_manifest.json` records SHA-256 fingerprints
for release sources and SOF/POF/UF2. The ZIP includes the same portable project
and excludes compiler databases and local dependencies.

## Physical-board acceptance

This task has not programmed either board. The new clock/image still needs
physical UART/Wi-Fi play, power-cycle and actual-phone acceptance. Routed timing,
simulation and browser results above are separate measurements.

1. Load both matching images and connect the three UART wires from README.md.
2. Join `FPGA-Chess`, open `http://192.168.4.1/` (or the USB-printed address),
   confirm connection and check that the console reports the qualified clock.
3. Play both colors; check reply/commit, undo, stop/resume, promotion and KEY0
   reconnect. The browser checks the full legal set and position readbacks.
4. Let a speed-round timer expire, including during promotion, and confirm a
   Spatial move followed by the opponent's selected search mode.
5. Run FPGA vs FPGA, pause during/between searches, reload and resume. Check
   captures, phase counters and continuation on the actual phone.
6. Power-cycle both boards, reload the volatile FPGA SOF, then reconnect/play.
