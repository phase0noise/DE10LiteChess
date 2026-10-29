# DE10-Lite Chess

This project targets the Terasic DE10-Lite / MAX 10 10M50DAF484C7G, with a Pico W
as the Wi-Fi and UART bridge. Chess move generation, evaluation and search live
in `rtl/`; the Pico serves the interface and transports commands.

Edit browser assets in `web/`. Regenerate `firmware/pico_chess/web_page.h` with
`web/embed_web.ps1` after UI changes; `tools/build_pico.ps1` does this automatically.
Keep the embedded page self-contained, including scripts, styles and artwork.

Use `tools/build_fpga.ps1` for FPGA builds and preserve its timing acceptance
checks. Keep FPGA, firmware and browser protocol changes compatible with each
other. `tools/verify.ps1` runs independent rules, protocol, RTL and search checks.

Use `tools/package.ps1` to build the portable project ZIP and refresh the source
and image manifest. Exclude compiler databases, local dependencies and caches.
Document measured results separately from physical-board acceptance.
