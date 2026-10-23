# FPGA Chess — DE10-Lite + Pico W

A self-contained port of Stochastic Chess to the **DE10-Lite (10M50DAF484C7G)**,
using the same **Pico W / 115200-baud UART / Wi-Fi webpage** workflow as the
oscilloscope example. All RTL, firmware, artwork, web files, and build scripts
are included here. Move this entire project folder wherever you want.

The FPGA generates legal moves, runs the recurrent field and up to six-ply
search with capture extensions, and chooses the computer's move. The Pico W hosts its own Wi-Fi network
and serves the complete page from flash. The browser handles your moves,
history, draw rules, and an independent check of the FPGA's complete legal set.

## Play

1. Load **`output_files/de10_chess.sof`** onto the DE10-Lite with Quartus
   Programmer, or run `tools/program_fpga.ps1`. Select the **10M50** device.
   The SOF configures volatile SRAM; reload it after cycling FPGA power.
2. Hold **BOOTSEL** while connecting the **Pico W** to USB. Copy
   **`output_files/pico_chess.uf2`** to the **RPI-RP2** drive. It reboots into
   the chess firmware.
3. Connect the same three UART wires as the example:

   | Pico W | DE10-Lite |
   | --- | --- |
   | **GP0 / TX** (physical pin 1) | **GPIO[8] / RX**, FPGA pin **W6** |
   | **GP1 / RX** (physical pin 2) | **GPIO[4] / TX**, FPGA pin **V8** |
   | **GND** | **GND** |

   These are **3.3 V logic** signals. Power each board through its normal USB
   supply and share ground. GPIO labels refer to the DE10-Lite GPIO header.
4. Connect your phone or computer to **`FPGA-Chess`**, password **`fpgachess`**.
5. Open **<http://192.168.4.1/>** with the included Pico W build. USB serial at
   **115200 baud** prints the actual address as `Open http://...` at startup.
6. Wait for **FPGA connected**, select your color, and press **New game**.
   Choose a piece and destination. Black starts with the FPGA playing white.

The page includes all four promotions, undo, board flipping, game restoration
after reload, PGN download, checkmate/stalemate, automatic draw rules, and
threefold/fifty-move draw claims. Lookahead includes Spatial and 2 through 6 ply;
the default targets **5 ply with a 10-second think budget**. Choose 3, 10, 20,
or 30 seconds. The FPGA keeps the last complete iteration if time runs out,
and the page shows the completed depth and cache reuse. The first complete
iteration can exceed a very short budget. **Play FPGA turn** resumes after a
stopped search or a reconnect.
Saved history is local to your browser; use one controlling browser tab.

Wi-Fi startup matches the oscilloscope reference: `WiFi.softAP(...)` uses the
Pico library's default AP configuration. The sketch does not force the mode or
IP address. The installed Arduino-Pico 6.0.0 library defaults to `192.168.4.1`;
another core version may choose a different address. The phone's Router/Gateway
address is also the Pico's address. The hotspot serves the local game without
internet access, so a phone may still ask whether to stay on an offline network.
Matching the reference's IP does not guarantee that this phone prompt disappears.

Dark mode is the default; the header's light/dark toggle remembers your choice.
Drag pieces with a mouse or finger, or tap a piece and its destination. Illegal
and off-board drops leave the piece in place, and promotions still offer all
four pieces. The page stays still for gestures that start on the board; start a
swipe outside the board to scroll the page.

The expanded engine uses a **4,096-entry position cache in M9K block RAM**,
ordered alpha-beta search, iterative deepening, and up to four capture/promotion
extension plies with check evasions. Evaluation blends middlegame and endgame
piece placement and includes passed/isolated/doubled pawns, bishop pairs, rook
files, and king shelter. The fitted design uses **29,371 / 49,760 logic elements
(59%)** and **917,128 / 1,677,312 memory bits (55%)**, occupying **125 / 182 M9K
blocks (69%)**, with passing 50 MHz timing.
On the independent mate-in-three regression set, it finds a winning first move
in **12/12 positions**, compared with **2/12** for the previous engine. This is
a focused tactical result, not an Elo estimate.
See [docs/ENGINE.md](docs/ENGINE.md) for the search design and controls. Load
**both new FPGA and Pico images** for the expanded controls.

**KEY0** resets the endpoint. **KEY1** starts evaluation on the currently loaded
position for bench diagnostics. LEDR9 indicates engine activity, LEDR8 the side
to move (off: white, on: black), and LEDR7..0 the recurrent field. HEX3..0 show
the encoded selected move; HEX4 shows part of the legal count and HEX5 the FSM
state nibble.

## Build

Prebuilt FPGA images (`de10_chess.sof` and `de10_chess.pof`) and Pico W firmware
(`pico_chess.uf2`) are included in `output_files/`, along with a SHA-256 manifest
for the project files and all three images.

From this project folder, with Quartus Prime Lite 23.1 and the Arduino Pico
core **6.0.0** installed:

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_fpga.ps1
powershell -ExecutionPolicy Bypass -File tools/build_pico.ps1
```

The scripts produce the SOF, POF, and UF2 in `output_files/`. Builds never upload
automatically. `build_fpga.ps1` rejects failing setup/hold/recovery/removal
timing and incomplete external-port timing coverage. Both build scripts use
paths relative to their own project; their executable paths can be overridden.

Run `powershell -ExecutionPolicy Bypass -File tools/package.ps1` after building
to refresh `output_files/build_manifest.json` and create a portable
`output_files/DE10LiteChess.zip`. Git tracks the programming images and manifest;
compiler databases, temporary reports, and the ZIP are ignored.

In Arduino IDE, select **Raspberry Pi Pico W**, **133 MHz**, **Pico SDK USB**,
**2 MB (no FS)**, and open `firmware/pico_chess/pico_chess.ino`. The generated
`web_page.h` already contains the page and chess artwork. After editing `web/`,
run `web/embed_web.ps1` or the Pico build script to regenerate it.

Edit `WIFI_NAME` and `WIFI_PASSWORD` in the sketch and rebuild to customize the
network. USB serial at 115200 prints the AP address at startup.

## Validate

See [docs/VALIDATION.md](docs/VALIDATION.md) for the measured build and test
results and the remaining physical-board checks.

```powershell
# Optional portable test tools: GHDL and python-chess, downloaded into .cache/.
powershell -ExecutionPolicy Bypass -File tools/setup_test_tools.ps1
powershell -ExecutionPolicy Bypass -File tools/verify.ps1
# Add the independently proven five-ply mate benchmark (longer simulation).
powershell -ExecutionPolicy Bypass -File tools/verify.ps1 -Strength
```

Verification uses Python 3.10+, `python-chess`, Node.js 18+, GHDL, and a native
C++11 compiler. `verify.ps1` accepts explicit executable paths and finds the
portable simulator, the local test dependency, VS Code's Node runtime, and
Questa's bundled GCC when installed here. No test imports the reference projects.
The browser smoke test uses Chrome and an explicitly simulated endpoint; it
checks UI behavior and is separate from physical FPGA acceptance.

See [docs/UART_PROTOCOL.md](docs/UART_PROTOCOL.md) for the binary transport and
engine command table. Pico W access-point support follows the
[Arduino-Pico Wi-Fi documentation](https://arduino-pico.readthedocs.io/en/latest/wifi.html).

## If the page opens but the FPGA does not connect

Check that both matching images are loaded, that **GP0 goes to GPIO[8]** and
**GP1 goes to GPIO[4]**, and that the grounds are joined. Press KEY0, then
**Reconnect**. The page reports UART failures and lets you retry the FPGA turn.
Use the Pico W, rather than a Pico without Wi-Fi.
