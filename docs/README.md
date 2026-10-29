# DE10-Lite Chess documentation

Start with the [project README](../README.md) for the engine overview, hardware
wiring and programming images.

## Design

| Document | Covers |
| --- | --- |
| [System architecture](ARCHITECTURE.md) | Browser/Pico/FPGA boundaries, RTL modules, a complete turn, parallel work, clocking and memory |
| [Search engine](ENGINE.md) | Search, evaluation, move ordering, draw handling, cache reuse and result publication |
| [Hardware pipeline](ADVANCED_ENGINE.md) | Evaluation stages, root PVS, arithmetic and timing constraints |
| [Parallel datapath](PARALLEL_ARCHITECTURE.md) | Lane widths, queue banking and scalar reference configurations |
| [UART protocol](UART_PROTOCOL.md) | Framing, HTTP bridge, commands, candidate bounds and telemetry byte layouts |

## Build and validation records

| Record | Covers |
| --- | --- |
| [Build results](build-results.txt) | Recorded 75 MHz timing, fitted resources and image sizes |
| [Validation](VALIDATION.md) | Completed checks, measurement limits and pending physical-board acceptance |
| [Datapath/search comparisons](advancement-results.json) | Controlled lane, root-scheduling and queue comparisons |
| [Completed mate cases](advanced-strength-results.json) | Results from the completed subset of the longer mate regression |

[history/](history) contains the original engine proposal and earlier parallel,
destination-scan and strength measurements. Those records describe previous
revisions; use the build and validation records above for the current images.
