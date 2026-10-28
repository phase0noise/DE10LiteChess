"""Start the copied Pi app as a real process with third-party packages disabled."""
import http.client
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "rpi"


class PortablePiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chess-flat-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.app = self.folder / "copied Pi app % $ apostrophe'"
        shutil.copytree(SOURCE, self.app, ignore=shutil.ignore_patterns("__pycache__", ".venv"))
        self.other = self.folder / "unrelated working directory"
        self.other.mkdir()
        self.env = os.environ.copy()
        self.env.update(PYTHONPATH="", PYTHONDONTWRITEBYTECODE="1",
                        CHESS_SPI_BUS="255", CHESS_SPI_DEVICE="255")

    def command(self, *args):
        return [sys.executable, "-S", "-B", str(self.app / "start.py"), *args]

    def run_command(self, *args):
        return subprocess.run(self.command(*args), cwd=self.other, env=self.env,
                              capture_output=True, text=True, timeout=5)

    def request(self, port, path):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, response.read(), dict(response.getheaders())
        finally:
            connection.close()

    def start(self):
        with socket.socket() as candidate:
            candidate.bind(("127.0.0.1", 0))
            port = candidate.getsockname()[1]
        process = subprocess.Popen(
            self.command("--no-setup", "--host", "127.0.0.1", "--port", str(port)),
            cwd=self.other, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        def stop():
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
        self.addCleanup(stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail("Real app exited: " + "".join(process.communicate()))
            try:
                if self.request(port, "/api/info")[0] == 200:
                    return process, port
            except (OSError, http.client.HTTPException):
                time.sleep(.03)
        self.fail("Real app did not start")

    def test_copied_flat_folder_serves_all_files_without_packages_or_original_cwd(self):
        _, port = self.start()
        for path in ["/", "/index.html", "/style.css", "/chess.js", "/fpga.js", "/app.js", "/pieces.png"]:
            with self.subTest(path=path):
                status, body, headers = self.request(port, path)
                self.assertEqual(status, 200)
                self.assertTrue(body)
                self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(self.request(port, "/healthz")[0], 503)
        for path in ["/spi_chess.py", "/start.py", "/../requirements.txt", "/web/index.html"]:
            self.assertEqual(self.request(port, path)[0], 404)

    def test_folder_can_be_moved_and_run_again_without_any_setup(self):
        process, _ = self.start()
        process.terminate()
        process.wait(timeout=3)
        moved = self.folder / "renamed"
        self.app.rename(moved)
        self.app = moved
        self.assertEqual(self.run_command("--check").returncode, 0)
        _, port = self.start()
        self.assertEqual(self.request(port, "/")[0], 200)

    def test_leftover_virtual_environment_and_missing_requirements_are_irrelevant(self):
        old = self.app / ".venv"
        old.mkdir()
        (old / ".chess-location").write_text("/wrong/old/PC/path")
        (self.app / "requirements.txt").unlink()
        _, port = self.start()
        self.assertEqual(self.request(port, "/")[0], 200)

    def test_check_reports_missing_file_without_system_changes(self):
        (self.app / "pieces.png").unlink()
        result = self.run_command("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing files: pieces.png", result.stderr)
        self.assertNotIn("apt-get", result.stdout)

    def test_occupied_port_exits_promptly_with_real_server_error(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            result = self.run_command("--no-setup", "--host", "127.0.0.1",
                                      "--port", str(listener.getsockname()[1]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot start the HTTP server", result.stderr)
        self.assertIn("--port 8081", result.stderr)

    def test_shell_aliases_use_the_same_entry_point_from_another_cwd(self):
        bash = shutil.which("bash")
        if not bash and Path("C:/Program Files/Git/bin/bash.exe").is_file():
            bash = "C:/Program Files/Git/bin/bash.exe"
        if not bash:
            self.skipTest("Bash is not installed")
        bin_folder = self.folder / "test-bin"
        bin_folder.mkdir()
        shim = bin_folder / "python3"
        shim.write_text('#!/usr/bin/env bash\nexec "$TEST_PYTHON" -S -B "$@"\n',
                        encoding="utf8", newline="\n")
        shim.chmod(0o755)
        posix_bin = bin_folder.as_posix()
        if os.name == "nt":
            posix_bin = "/" + posix_bin[0].lower() + posix_bin[2:]
        env = dict(self.env, TEST_PYTHON=Path(sys.executable).as_posix(), TEST_BIN=posix_bin)
        for script in ["start.sh", "run.sh", "setup.sh"]:
            result = subprocess.run(
                [bash, "--noprofile", "--norc", "-c",
                 'export PATH="$TEST_BIN:/usr/bin:/bin"; exec bash "$@"',
                 "alias-test", (self.app / script).as_posix(), "--check"],
                cwd=self.other, env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("All Pi files are present", result.stdout)


if __name__ == "__main__":
    unittest.main()
