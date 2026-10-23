# Port validation — October 21, 2026

The project includes its own FPGA sources, Pico firmware, artwork, web assets,
and test/build scripts. Quartus and Arduino builds run from this project folder.
`tools/check_project.py` checks that every QSF source is inside the project and
that all firmware/browser assets are present. It also checks the staged ZIP.

## Functional results

- Browser rules match **147 independently generated python-chess positions**:
  complete legal sets, SAN, every resulting FEN, position bytes, check status,
  and insufficient material. Start-position perft: 20 / 400 / 8902; Kiwipete:
  48 / 2039. Repetition, en-passant repetition keys, intended-move draw claims,
  and undo are covered.
- The copied VHDL engine matches all **147** independent legal sets and attack
  maps, including castling, en passant, underpromotion, checkmate and stalemate.
  Candidate explanation sums, configuration/routing RAM, both policy pages,
  response LUT, local bias and cold-start field state also pass.
- **10 three-ply tactical fixtures** pass on both colors: mate over material,
  poisoned capture, royal fork, an opponent's en-passant reply and promotion.
  Expected best moves also check committed board/rights/EP/turn and stale commit
  rejection. The original search logic and policy defaults are retained.
- The **new UART bridge** passes VHDL simulation: status framing and CRC,
  duplicate mutation retries, corrupt/truncated/oversize/framing-error requests,
  recovery, maximum-length configuration, complete opening legal-set readback,
  hardware selection, position commit and stale commit rejection.
- The actual **Pico C++ packet parser** passes native tests for the standard
  CCITT-FALSE check vector, frame sizes through 1024 reply bytes, corruption,
  malformed lengths, noise and resynchronization.
- Browser transport tests verify legal-set/board mismatches prevent commit,
  cancellation, and explicit disconnected-hardware errors.
- **Chrome desktop and 390 px mobile** checks pass: connection, selection,
  legal destinations, human move, an explicitly simulated FPGA reply, history,
  undo, flipping and reload. The October 22 UI update also passes persisted
  light/dark themes, mouse and touch dragging, illegal/off-board/cancelled drops,
  dragging on a flipped board, promotion selection/cancellation, blocked page
  scrolling over the board, and working page scrolling outside it. Screenshots
  were inspected. This UI test uses a simulated protocol endpoint and does not
  establish physical FPGA operation or acceptance on an actual phone.

Tools: GHDL 6.0.0; python-chess 1.11.2; Node.js 22.18.0; GCC 7.4.0; Chrome.

## Build results

Final build measurements are included in `build-results.txt` alongside this
document. Quartus Prime Lite 23.1 targets the actual **10M50DAF484C7G** and uses
MAX 10 M9K memory inference. `build_fpga.ps1` requires nonnegative setup, hold,
recovery and removal slack across all available operating conditions and zero
unconstrained clocks/input/output ports. Asynchronous inputs are excluded only
at the reset input and the first sampling registers; display/UART outputs have
no synchronous external receiver.

The Pico W firmware compiles with Arduino-Pico **6.0.0**, **133 MHz**, at about
**22% flash** and **29% RAM**. The generated header contains the entire webpage
and artwork. There are no CDN or internet requests during play.

The Wi-Fi startup now matches the oscilloscope reference's `WiFi.softAP(...)`
call, without forcing AP mode or a static address. The installed core's default
AP address is `192.168.4.1`, also printed on USB serial. Removing the phone's
offline-network confirmation has not been established on physical hardware;
the reference has no special internet-validation handling either.

`output_files/build_manifest.json` records SHA-256 fingerprints for all release
sources and all three programming images (SOF, POF, and UF2). The portable ZIP
contains those sources and images; compiler databases, temporary files and test
dependencies are omitted.

## Physical-board acceptance

No board has been programmed by this task. Physical UART/Wi-Fi gameplay,
power-cycle behavior and radio reliability remain to be checked on your boards.
Compilation, simulations, and browser tests are recorded separately above.

For the first hardware check:

1. Load both matching images and connect the three wires listed in README.md.
2. Join **FPGA-Chess** and open **http://192.168.4.1/**, or the address printed
   on USB serial. Confirm **FPGA connected**.
3. Play as white, make a move and wait for the FPGA reply. The browser compares
   the complete legal set and both position readbacks before accepting the reply.
4. Start a game as black and verify that the FPGA plays white first. Check
   undo, stop/resume, promotion when reached, and reconnect after KEY0 reset.
5. Power cycle each board, reload the FPGA SOF, and repeat the connection check.
