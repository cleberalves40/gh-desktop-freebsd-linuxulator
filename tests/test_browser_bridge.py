import importlib.util
import socket
import tempfile
import threading
import unittest
from pathlib import Path


BRIDGE_PATH = Path(__file__).resolve().parents[1] / "script" / "gh-desktop-browser-bridge.py"
SPEC = importlib.util.spec_from_file_location("browser_bridge", BRIDGE_PATH)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class BrowserBridgeTests(unittest.TestCase):
    def test_validates_http_urls(self):
        self.assertTrue(BRIDGE.validate_url("https://github.com/desktop"))
        self.assertTrue(BRIDGE.validate_url("http://localhost:8080"))
        self.assertFalse(BRIDGE.validate_url("file:///etc/passwd"))
        self.assertFalse(BRIDGE.validate_url("https:///missing-host"))
        self.assertFalse(BRIDGE.validate_url("https://example.com/\n"))

    def test_validates_supported_oauth_schemes(self):
        schemes = (
            "x-github-client",
            "x-github-desktop-dev-auth",
            "x-github-desktop-auth",
        )
        for scheme in schemes:
            with self.subTest(scheme=scheme):
                self.assertTrue(BRIDGE.validate_oauth_url(f"{scheme}://oauth"))
        self.assertFalse(BRIDGE.validate_oauth_url("https://oauth"))

    def test_forwards_all_oauth_schemes_as_legacy_scheme(self):
        schemes = (
            "x-github-client",
            "x-github-desktop-dev-auth",
            "x-github-desktop-auth",
        )
        for scheme in schemes:
            with self.subTest(scheme=scheme):
                self.assert_forwarded_url(
                    f"{scheme}://oauth?code=probe&state=test",
                    "x-github-client://oauth?code=probe&state=test",
                )

    def assert_forwarded_url(self, source_url, expected_url):
        with tempfile.TemporaryDirectory() as directory:
            socket_path = str(Path(directory) / "callback.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(socket_path)
            server.listen(1)
            received = {}

            def receive_url():
                connection, _ = server.accept()
                with connection:
                    received["url"] = connection.recv(8192).decode().strip()

            worker = threading.Thread(target=receive_url)
            worker.start()
            result = BRIDGE.open_oauth_url(socket_path, source_url)
            worker.join()
            server.close()

            self.assertEqual(result, 0)
            self.assertEqual(received["url"], expected_url)


if __name__ == "__main__":
    unittest.main()