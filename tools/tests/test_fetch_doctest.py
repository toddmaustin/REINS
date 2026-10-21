"""Exercise real HTTPS trust, download diagnostics and offline cached dependencies."""
from contextlib import redirect_stdout
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from tools import fetch_doctest

ROOT = Path(__file__).resolve().parents[2]
TLS = Path(__file__).resolve().parent / "tls"
PAYLOAD = b"local HTTPS dependency test\n"


class DownloadTrustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Start cls's loopback HTTPS server and create its retained artifact directory."""
        parent = Path(os.environ.get("REINS_TEST_OUTPUT_DIR", ROOT / "test-results"))
        parent = parent / "download-regressions"
        parent.mkdir(parents=True, exist_ok=True)
        cls.output = Path(tempfile.mkdtemp(prefix="tls-", dir=parent))

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                """Reply to this handler's GET request with the fixed public test payload."""
                self.send_response(200)
                self.send_header("Content-Length", str(len(PAYLOAD)))
                self.end_headers()
                self.wfile.write(PAYLOAD)

            def log_message(self, format_string, *args):
                """Retain the server log entry produced by applying args to format_string."""
                with (cls.output / "server.log").open("a") as log:
                    log.write(format_string % args + "\n")

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.addClassCleanup(server.server_close)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(TLS / "server.pem", TLS / "server-key.pem")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        cls.url = f"https://127.0.0.1:{server.server_port}/doctest.tar.gz"
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        cls.addClassCleanup(thread.join, 5)
        cls.addClassCleanup(server.shutdown)

    def setUp(self):
        """Create the retained output directory for this individual test case."""
        self.artifacts = self.output / self._testMethodName
        self.artifacts.mkdir()

    def run_python(self, program, *, trusted=False, url=None):
        """Run program under -E against url (default: local server); trusted selects its CA."""
        environment = dict(os.environ)
        for name in ["SSL_CERT_FILE", "SSL_CERT_DIR"]:
            environment.pop(name, None)
        environment.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
        if trusted:
            environment["SSL_CERT_FILE"] = str(TLS / "ca.pem")
        command = [sys.executable, "-E", "-s", "-B", "-c", program,
                   url or self.url, str(self.artifacts)]
        (self.artifacts / "command.json").write_text(json.dumps({
            "command": command, "SSL_CERT_FILE": environment.get("SSL_CERT_FILE")}, indent=2) + "\n")
        out = self.artifacts / "stdout.log"
        err = self.artifacts / "stderr.log"
        with out.open("wb") as stdout, err.open("wb") as stderr:
            result = subprocess.run(command, cwd=ROOT, env=environment,
                                    stdout=stdout, stderr=stderr, timeout=10, check=False)
        return result.returncode, out.read_bytes(), err.read_text()

    def cli_program(self):
        """Return child code invoking the fetch CLI with isolated URL/cache arguments."""
        return ("import sys; from pathlib import Path; from tools import fetch_doctest as fetch; "
                "fetch.URL = sys.argv[1]; fetch.ROOT = Path(sys.argv[2]); sys.exit(fetch.cli())")

    def test_untrusted_issuer_fails_with_actionable_cli_error(self):
        """Require rejection and useful diagnostics for the untrusted local test issuer."""
        code, output, error = self.run_python(self.cli_program())
        self.assertEqual(code, 1)
        self.assertEqual(output, b"")
        self.assertIn("HTTPS certificate verification failed", error)
        self.assertIn("ca-certificates", error)
        self.assertIn("SSL_CERT_FILE=", error)
        self.assertIn("Python CA paths:", error)
        self.assertNotIn("Traceback", error)
        self.assertFalse((self.artifacts / ".deps").exists())

    def test_trusted_bundle_is_honored_under_python_E(self):
        """Confirm SSL_CERT_FILE trusts the local CA even when Python uses -E."""
        code, output, error = self.run_python(
            "import sys; from tools.fetch_doctest import download_archive; "
            "sys.stdout.buffer.write(download_archive(sys.argv[1]))", trusted=True)
        self.assertEqual(code, 0, error)
        self.assertEqual(output, PAYLOAD)
        self.assertEqual(error, "")

    def test_trusted_issuer_still_rejects_wrong_hostname(self):
        """Require hostname verification even after explicitly trusting the test CA."""
        # Only 127.0.0.1 appears in the certificate; localhost must be rejected.
        code, _, error = self.run_python(self.cli_program(), trusted=True,
                                        url=self.url.replace("127.0.0.1", "localhost"))
        self.assertEqual(code, 1)
        self.assertIn("HTTPS certificate verification failed", error)
        self.assertIn("Hostname mismatch", error)
        self.assertFalse((self.artifacts / ".deps").exists())

    def test_verified_cache_does_not_need_tls_configuration(self):
        """Reuse validated cached files without downloading or reading a missing CA file."""
        files = {"doctest/doctest.h": b"cached header\n", "LICENSE.txt": b"cached license\n"}
        destination = self.artifacts / ".deps/doctest-2.4.12"
        for name, contents in files.items():
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        hashes = {name: hashlib.sha256(contents).hexdigest() for name, contents in files.items()}
        with patch.object(fetch_doctest, "ROOT", self.artifacts), \
             patch.object(fetch_doctest, "FILES", hashes), \
             patch.dict(os.environ, {"SSL_CERT_FILE": str(self.artifacts / "missing-ca.pem")}), \
             patch.object(fetch_doctest, "download_archive", side_effect=AssertionError("unexpected download")), \
             (self.artifacts / "stdout.log").open("w") as log, redirect_stdout(log):
            self.assertEqual(fetch_doctest.cli(), 0)
        for name, contents in files.items():
            self.assertEqual((destination / name).read_bytes(), contents)


if __name__ == "__main__":
    unittest.main()
