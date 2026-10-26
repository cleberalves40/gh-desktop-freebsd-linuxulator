# GitHub Desktop Linuxulator Installer

A standalone FreeBSD installer and browser/OAuth bridge for running the
`cleberalves40/gh-desktop` Linux build inside an existing Ubuntu Linuxulator
chroot. This is not a native FreeBSD port.

## Scope

The installer builds the fork's `development` branch by default, installs a
desktop launcher, mounts only a configured repositories directory read-write
while the app is running, and routes browser URLs through the native host
browser. Firefox remains the host browser; the Linuxulator root and host browser
defaults are not changed.

OAuth callbacks use a separate host handler. It accepts the production,
development, and legacy `x-github-client` schemes. The development and
production-specific schemes are rewritten to `x-github-client` before
forwarding so older callback listeners can process them. The callback socket is
private to the desktop user and active only during an app session.

## Requirements

- FreeBSD amd64 with Linuxulator enabled.
- An Ubuntu chroot at `/compat/ubuntu`, with `/proc` mounted and
  `compat.linux.emul_path` already set to `/compat/ubuntu`.
- Root access for installation and system desktop-file registration.
- A graphical desktop session with X11, session D-Bus, host Python 3,
  `xdg-open`, and `xdg-mime`.
- Network access to GitHub, Ubuntu package repositories, and `nodejs.org`.

The build uses GCC 10 and the Node.js version pinned by the fork. Installation
builds the app inside the chroot and can take a while on first run.

## Install

From this repository, run:

```sh
sudo sh ./script/freebsd-linuxulator.sh install
```

The default writable repository directory is `~/Repositories`. To choose a
different directory below your home:

```sh
sudo env GH_DESKTOP_REPO_ROOT="$HOME/src/Repositories" \
  sh ./script/freebsd-linuxulator.sh install
```

For an existing app installation, install or refresh browser handoff without
rebuilding:

```sh
sudo sh ./script/freebsd-linuxulator.sh configure-browser
```

Launch GitHub Desktop from the Applications menu. The terminal alternative is:
Launch GitHub Desktop from the Applications menu (recommended so the callback
listener stays attached to the desktop session). The desktop entry can also be
launched with GIO:

```sh
gio launch /usr/local/share/applications/gh-desktop-linuxulator.desktop
```

The terminal alternative is:

```sh
sh ./script/freebsd-linuxulator.sh run
```

Detailed setup, isolation, authentication, and recovery steps are in
[docs/freebsd-linuxulator.md](docs/freebsd-linuxulator.md).

## Validate

Run the bridge unit tests and syntax checks:

```sh
python3 -m unittest discover -s tests -v
python3 -m py_compile script/gh-desktop-browser-bridge.py
sh -n script/freebsd-linuxulator.sh
```

To verify desktop registrations on the host:

```sh
gio mime x-scheme-handler/x-github-client
gio mime x-scheme-handler/x-github-desktop-dev-auth
gio mime x-scheme-handler/x-github-desktop-auth
```

Do not paste callback URLs, authorization codes, tokens, or unredacted app logs
into chat or issue reports.