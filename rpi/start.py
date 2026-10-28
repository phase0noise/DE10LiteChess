#!/usr/bin/env python3
"""Copy this folder to the Pi, then run: python3 start.py"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

FOLDER = Path(__file__).resolve().parent


def root_command(*command):
    prefix = [] if os.geteuid() == 0 else ["sudo"]
    subprocess.run([*prefix, *command], check=True)


def on_raspberry_pi():
    if sys.platform != "linux":
        return False
    model = Path("/proc/device-tree/model")
    return shutil.which("raspi-config") is not None or (
        model.is_file() and b"Raspberry Pi" in model.read_bytes()
    )


def prepare_pi():
    # Only Pi OS needs native SPI setup. The HTTP app itself has no dependencies.
    if not on_raspberry_pi():
        return True
    if not os.environ.get("INVOCATION_ID") and shutil.which("systemctl"):
        running = subprocess.run(["systemctl", "is-active", "--quiet", "de0cv-chess.service"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if running.returncode == 0:
            print("Stopping the previous chess service so this copy can use SPI.", flush=True)
            root_command("systemctl", "stop", "de0cv-chess.service")
    if importlib.util.find_spec("spidev") is None:
        print("Installing Raspberry Pi SPI support (first run only).", flush=True)
        root_command("apt-get", "update")
        root_command("apt-get", "install", "-y", "python3-spidev")
        importlib.invalidate_caches()
        if importlib.util.find_spec("spidev") is None:
            os_python = Path("/usr/bin/python3")
            if os_python.is_file() and os_python.resolve() != Path(sys.executable).resolve():
                os.execv(str(os_python), [str(os_python), str(FOLDER / "start.py"), *sys.argv[1:]])
            raise SystemExit("The Pi OS SPI driver could not be loaded after installation.")
    bus = int(os.environ.get("CHESS_SPI_BUS", "0"))
    device = int(os.environ.get("CHESS_SPI_DEVICE", "0"))
    spi_path = Path(f"/dev/spidev{bus}.{device}")
    if not spi_path.exists() and (bus, device) == (0, 0) and shutil.which("raspi-config"):
        print("Enabling SPI.", flush=True)
        root_command("raspi-config", "nonint", "do_spi", "0")
        if not spi_path.exists():
            print("SPI is enabled. Reboot once, then run python3 start.py again.", flush=True)
            return False
    if spi_path.exists() and not os.access(spi_path, os.R_OK | os.W_OK) and os.geteuid() != 0:
        import pwd
        user = pwd.getpwuid(os.getuid()).pw_name
        root_command("usermod", "-aG", "spi", user)
        print("Starting with SPI group access.", flush=True)
        settings = [f"{key}={value}" for key, value in os.environ.items()
                    if key.startswith("CHESS_")]
        os.execvp("sudo", ["sudo", "-u", user, "-g", "spi", "--", "env", *settings,
                          sys.executable, str(FOLDER / "start.py"), *sys.argv[1:]])
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("CHESS_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=os.environ.get("CHESS_PORT", "8080"))
    parser.add_argument("--check", action="store_true", help="Check the copied files without changing the Pi")
    parser.add_argument("--no-setup", action="store_true", help="Start without changing system settings")
    parser.add_argument("--diagnose", nargs=argparse.REMAINDER, help="Read FPGA status, e.g. --diagnose info")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("port must be 1..65535")
    required = ("web_app.py", "spi_chess.py", "index.html", "style.css",
                "chess.js", "fpga.js", "app.js", "pieces.png")
    missing = [name for name in required if not (FOLDER / name).is_file()]
    if missing:
        raise SystemExit("Missing files: " + ", ".join(missing) + ". Copy the whole Pi folder.")
    if args.check:
        print("All Pi files are present. No virtual environment or web packages are needed.")
        return
    # Use the OS interpreter when called from an activated virtual environment.
    if sys.prefix != sys.base_prefix:
        os.execv(sys._base_executable, [sys._base_executable, str(FOLDER / "start.py"), *sys.argv[1:]])
    if not args.no_setup and not prepare_pi():
        return
    if args.diagnose is not None:
        from spi_chess import main as diagnose
        diagnose(args.diagnose)
        return
    from web_app import serve
    serve(args.host, args.port)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        raise SystemExit(f"Could not start chess: {error}") from error
