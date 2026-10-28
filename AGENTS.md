# Raspberry Pi app

The `rpi/` folder is a standalone DE0-CV SPI app. Keep every runtime file flat
inside it and preserve one-command startup: `python3 start.py`.

Resolve files beside the running script. Never require a parent checkout,
fixed username, installation directory, virtual environment or manual pip step.
Moving or renaming the folder must not require setup again. Keep first-run Pi
SPI setup automatic; keep the existing network and foreground operation.

Use `tools/package_rpi.py` to build the standalone ZIP. Do not include local
environments, dependency caches, bytecode or service templates. Test actual
startup and HTTP requests from copied folders with third-party packages disabled.
