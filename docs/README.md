# Documentation

| Read | Covers |
| --- | --- |
| [Engine](ENGINE.md) | Search, evaluation, move ordering, draw handling and RAM tables |
| [System architecture](ARCHITECTURE.md) | Browser, Pico and FPGA responsibilities; a turn from upload to commit |
| [Hardware pipeline](ADVANCED_ENGINE.md) | Four-lane datapath, PVS, arithmetic stages and clock constraints |
| [Parallel operations](PARALLEL_ARCHITECTURE.md) | Lane widths, queue banking and scalar reference configurations |
| [UART protocol](UART_PROTOCOL.md) | Packets, commands, candidate bounds and telemetry layouts |
| [Build results](build-results.txt) | Qualified 75 MHz timing, device resources and image sizes |
| [Validation](VALIDATION.md) | Completed checks, measurement limits and physical-board status |

Current measurements: [datapath/search comparisons](advancement-results.json)
and [completed mate cases](advanced-strength-results.json).

[history/](history) keeps the original engine proposal and older parallel,
destination-scan and strength measurements. Those files describe earlier
revisions; the current build results and validation record are linked above.
