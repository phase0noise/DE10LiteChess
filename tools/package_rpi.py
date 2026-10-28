"""Build the standalone Pi ZIP; only the listed runtime files are included."""
from hashlib import sha256
import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

FILES = ("README.md", ".gitignore", "start.py", "start.sh", "run.sh", "setup.sh",
         "web_app.py", "spi_chess.py", "requirements.txt", "index.html",
         "style.css", "chess.js", "fpga.js", "app.js", "pieces.png")


def package(source, destination):
    source = source.resolve()
    hashes = {}
    for name in FILES:
        data = (source / name).read_bytes()
        if name.endswith((".py", ".sh")) and b"\r" in data:
            raise ValueError(f"Use Linux line endings: {name}")
        hashes[name] = sha256(data).hexdigest()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name in FILES:
            archive.write(source / name, "rpi/" + name)
        archive.writestr("rpi/manifest.json", json.dumps(
            {"run": "python3 start.py", "sha256": hashes}, indent=2) + "\n")
    print(f"Pi folder: {source}")
    print(f"Pi ZIP: {destination.resolve()}")


if __name__ == "__main__":
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=project / "rpi")
    parser.add_argument("--output", type=Path, default=project / "output_files/rpi.zip")
    args = parser.parse_args()
    package(args.source, args.output)
