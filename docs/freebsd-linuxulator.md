# GitHub Desktop on FreeBSD with Linuxulator

This installer builds the `development` branch of this fork as a Linux x86-64
application inside an existing Ubuntu Linuxulator chroot. The tested fork
version is `3.6.9-beta1`; this is not a native FreeBSD build.

## Requirements

- FreeBSD amd64 with Linuxulator enabled.
- An Ubuntu chroot at `/compat/ubuntu`, with the Linuxulator mounts active,
  including `/proc`.
- Root access for package installation and mount setup.
- A graphical desktop session with X11 `DISPLAY`, a session D-Bus address, and
  `xdg-mime`, `xdg-open`, and Python 3 available on the host for browser
  handoff and OAuth callback registration.
- Internet access to GitHub, Ubuntu package repositories, and `nodejs.org`.

The installer installs Linux build and runtime dependencies in the chroot,
downloads the exact Node.js version listed in `.node-version` and verifies its
SHA-256 checksum, clones this fork, and builds the app. GCC 10 is required by
the C++20 build dependencies. Re-running the installer fast-forwards the source
to the configured branch and rebuilds it; local source changes stop the update
rather than being overwritten.

## Install

From the root of this repository, run as the desktop user:

```sh
sudo sh ./script/freebsd-linuxulator.sh install
```

By default, repositories are stored in `~/Repositories`. To choose another
directory under your home:

```sh
sudo env GH_DESKTOP_REPO_ROOT="$HOME/src/Repositories" \
  sh ./script/freebsd-linuxulator.sh install
```

The installer creates the default directory if needed, saves its location in
`~/.config/gh-desktop-linuxulator.conf`, installs a launcher in the desktop
applications menu, and configures browser handoff. HTTP/HTTPS handlers are
changed only in the isolated Linuxulator profile. They forward URLs through a
per-user Unix socket to the host's `xdg-open`, which uses the existing host
browser association (Firefox on the tested host). The bridge socket is mode
`0600` and runs only while GitHub Desktop is open.

OAuth uses a separate host-side handler for `x-github-client`,
`x-github-desktop-dev-auth`, and `x-github-desktop-auth`. Development and
production-specific callback schemes are normalized to `x-github-client`
before reaching the listener, preserving compatibility with older listener
processes. The root listener is tied to the app session and relaunches the Linux
app with the callback URL without another `sudo` prompt. Its socket is owned by
the desktop user and mode `0600`. The host browser default and global
Linuxulator root are not changed.

The HTTP/HTTPS handoff and an interactive OAuth sign-in have been verified on
the tested host.
For an existing installation, configure the browser handoff without rebuilding:

```sh
sudo sh ./script/freebsd-linuxulator.sh configure-browser
```

If GitHub shows “If your browser does not redirect you back, please visit this
setup page to continue,” click **this setup page**. If Firefox asks to open
GitHub Desktop, accept the prompt. `configure-browser` registers the development
scheme used by the setup page and forwards it to the active callback listener.

Launch **GitHub Desktop** from the Applications menu so the app and callback
listener remain attached to the desktop session. You can also use GIO:

```sh
gio launch /usr/local/share/applications/gh-desktop-linuxulator.desktop
```

For terminal troubleshooting, run:

```sh
sh ./script/freebsd-linuxulator.sh run
```

While the app is running, only the configured repository directory is mounted
read-write into the chroot at
`/mnt/gh-desktop-repositories-<user-id>`. The mount is removed when the app
exits. The rest of the host home directory is not mounted by this installer.
The app profile and credentials are kept separately in the chroot under
`/home/gh-desktop-<user-id>` and use the session Secret Service when available.
The Ubuntu Focal Git is used because the upstream bundled Git requires a newer
glibc than Focal provides. The installer keeps the original bundled executables
as `git.bundled`, points the app and its Git helper at the chroot's `/usr/bin/git`,
and installs Git LFS from Ubuntu. Git and LFS are therefore limited to the
versions shipped by that Ubuntu release. The launcher disables GPU acceleration
because it is needed for reliable renderer startup in the tested Linuxulator
session.

Electron's Chromium sandbox is disabled with `--no-sandbox` because the required
Linux namespaces are unavailable in this Linuxulator setup. Use a dedicated
repository directory and only open repositories intended for this environment.
The app can edit files and create commits in that directory; review changes
before pushing to any remote.

## Network and authentication status

HTTPS requests to GitHub, the GitHub API, and `nodejs.org`, plus `git ls-remote`
against the public fork, succeeded from the Ubuntu chroot. This confirms access
to those endpoints; it does not prove unrestricted Internet access, OAuth
completion, private repository access, or authenticated push access.

The desktop entry forwards the GitHub callback URL to the Linux app. Complete
sign-in in the normal browser/app flow without placing credentials in shell
arguments or configuration files. Private remote access should be tested with a
non-critical repository before relying on it. To inspect protocol registration,
run `gio mime` for `x-github-client`, `x-github-desktop-dev-auth`, and
`x-github-desktop-auth`. Never copy callback URLs, authorization codes, tokens,
or unredacted app logs into chat or issue reports.
