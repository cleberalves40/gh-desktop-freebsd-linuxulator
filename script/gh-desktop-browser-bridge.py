#!/usr/bin/env python3
import argparse
import os
import signal
import socket
import stat
import subprocess
import sys
from urllib.parse import urlsplit


def validate_url(url):
    if any(ord(character) < 32 for character in url):
        return False
    try:
        parsed = urlsplit(url)
    except ValueError:
        return False
    return parsed.scheme in ("http", "https") and bool(parsed.netloc)


def validate_oauth_url(url):
    if any(ord(character) < 32 for character in url):
        return False
    try:
        parsed = urlsplit(url)
    except ValueError:
        return False
    return parsed.scheme in (
        "x-github-client",
        "x-github-desktop-dev-auth",
        "x-github-desktop-auth",
    ) and bool(parsed.netloc)


def serve(socket_path, handler, socket_owner=None):
    if os.path.lexists(socket_path):
        if not stat.S_ISSOCK(os.lstat(socket_path).st_mode):
            raise RuntimeError("browser bridge path exists and is not a socket")
        if check_server(socket_path):
            raise RuntimeError("browser bridge is already running")
        os.unlink(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(socket_path)
        if socket_owner:
            os.chown(socket_path, *socket_owner)
        os.chmod(socket_path, 0o600)
        server.listen(8)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True:
            connection, _ = server.accept()
            with connection:
                data = bytearray()
                while len(data) <= 8192 and b"\n" not in data:
                    chunk = connection.recv(1024)
                    if not chunk:
                        break
                    data.extend(chunk)
                if len(data) > 8192:
                    continue
                url = data.split(b"\n", 1)[0].decode("utf-8", "replace")
                handler(url)
    finally:
        server.close()
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass


def open_url(socket_path, url):
    if not validate_url(url):
        print("Only HTTP and HTTPS URLs can be opened", file=sys.stderr)
        return 2
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall(url.encode("utf-8") + b"\n")
    return 0


def open_oauth_url(socket_path, url):
    if not validate_oauth_url(url):
        print("Unsupported GitHub Desktop OAuth URL", file=sys.stderr)
        return 2
    parsed_url = urlsplit(url)
    if parsed_url.scheme != "x-github-client":
        url = parsed_url._replace(scheme="x-github-client").geturl()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall(url.encode("utf-8") + b"\n")
    return 0


def check_server(socket_path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        try:
            client.connect(socket_path)
        except OSError:
            return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--serve", action="store_true")
    mode.add_argument("--serve-oauth", action="store_true")
    mode.add_argument("--open-url")
    mode.add_argument("--open-oauth")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--chroot", default="/compat/ubuntu")
    parser.add_argument("--uid", type=int)
    parser.add_argument("--gid", type=int)
    parser.add_argument("--linux-home")
    parser.add_argument("--display", default=":0")
    parser.add_argument("--dbus-session-bus-address", default="")
    parser.add_argument("--xauthority", default="")
    args = parser.parse_args()

    if args.serve:
        serve(
            args.socket,
            lambda url: subprocess.Popen(
                ["/usr/local/bin/xdg-open", url],
                close_fds=True,
                start_new_session=True,
            )
            if validate_url(url)
            else None,
        )
        return 0
    if args.serve_oauth:
        if args.uid is None or args.gid is None or not args.linux_home:
            parser.error("--serve-oauth requires --uid, --gid, and --linux-home")
        socket_owner = (args.uid, args.gid)

        def dispatch(url):
            if not validate_oauth_url(url):
                return
            subprocess.Popen(
                [
                    "/usr/sbin/chroot",
                    "-u",
                    str(args.uid),
                    "-g",
                    str(args.gid),
                    args.chroot,
                    "/usr/bin/env",
                    f"HOME={args.linux_home}",
                    f"XDG_CONFIG_HOME={args.linux_home}/.config",
                    f"XDG_CACHE_HOME={args.linux_home}/.cache",
                    f"XDG_DATA_HOME={args.linux_home}/.local/share",
                    f"XDG_RUNTIME_DIR={args.linux_home}/.runtime",
                    f"DISPLAY={args.display}",
                    f"DBUS_SESSION_BUS_ADDRESS={args.dbus_session_bus_address}",
                    f"XAUTHORITY={args.xauthority}",
                    "GDK_BACKEND=x11",
                    "LOCAL_GIT_DIRECTORY=/usr",
                    "GIT_EXEC_PATH=/usr/lib/git-core",
                    "GIT_CONFIG_SYSTEM=/dev/null",
                    "/opt/gh-desktop/dist/desktop-linux-x64/desktop",
                    "--no-sandbox",
                    "--disable-gpu",
                    url,
                ],
                close_fds=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )

        serve(args.socket, dispatch, socket_owner)
        return 0
    if args.check:
        return 0 if check_server(args.socket) else 1
    if args.open_url is not None:
        return open_url(args.socket, args.open_url)
    return open_oauth_url(args.socket, args.open_oauth)


if __name__ == "__main__":
    raise SystemExit(main())