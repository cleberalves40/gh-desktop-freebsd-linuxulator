#!/bin/sh
set -eu

CHROOT=${LINUX_CHROOT:-/compat/ubuntu}
APP_DIR=/opt/gh-desktop
REPOSITORY=https://github.com/cleberalves40/gh-desktop.git
BRANCH=${GH_DESKTOP_BRANCH:-development}
LAUNCHER=/usr/local/libexec/gh-desktop-linuxulator
DESKTOP_FILE=/usr/local/share/applications/gh-desktop-linuxulator.desktop
OAUTH_DESKTOP_FILE=/usr/local/share/applications/gh-desktop-oauth-handler.desktop
HOST_BROWSER_BRIDGE=/usr/local/libexec/gh-desktop-browser-bridge

fail() {
  printf '%s\n' "gh-desktop-linuxulator: $*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage:' \
    '  sudo script/freebsd-linuxulator.sh install' \
    '  sudo script/freebsd-linuxulator.sh configure-browser' \
    '  sudo env GH_DESKTOP_REPO_ROOT=/home/user/Repositories script/freebsd-linuxulator.sh install' \
    '  script/freebsd-linuxulator.sh run'
}

require_root() {
  [ "$(id -u)" -eq 0 ] || fail 'run install with sudo'
}

resolve_user() {
  GH_DESKTOP_USER=${GH_DESKTOP_USER:-${SUDO_USER:-$(id -un)}}
  [ "$GH_DESKTOP_USER" != root ] || fail 'run from the desktop user account, not a root shell'
  GH_DESKTOP_UID=$(id -u "$GH_DESKTOP_USER") || fail "unknown user: $GH_DESKTOP_USER"
  GH_DESKTOP_GID=$(id -g "$GH_DESKTOP_USER") || fail "unknown group for $GH_DESKTOP_USER"
  GH_DESKTOP_HOME=$(getent passwd "$GH_DESKTOP_USER" | awk -F: '{print $6}')
  [ -n "$GH_DESKTOP_HOME" ] || fail "cannot determine home for $GH_DESKTOP_USER"
  LINUX_HOME="/home/gh-desktop-$GH_DESKTOP_UID"
}

resolve_repository_root() {
  if [ -z "${GH_DESKTOP_REPO_ROOT:-}" ] && [ -r "$GH_DESKTOP_HOME/.config/gh-desktop-linuxulator.conf" ]; then
    GH_DESKTOP_REPO_ROOT=$(sed -n 's/^GH_DESKTOP_REPO_ROOT=//p' \
      "$GH_DESKTOP_HOME/.config/gh-desktop-linuxulator.conf" | head -n 1)
  fi

  GH_DESKTOP_REPO_ROOT=${GH_DESKTOP_REPO_ROOT:-"$GH_DESKTOP_HOME/Repositories"}
  if [ ! -d "$GH_DESKTOP_REPO_ROOT" ]; then
    [ "${1:-}" = install ] && [ "$GH_DESKTOP_REPO_ROOT" = "$GH_DESKTOP_HOME/Repositories" ] || \
      fail "directory not found: $GH_DESKTOP_REPO_ROOT"
    mkdir -p "$GH_DESKTOP_REPO_ROOT"
    chown "$GH_DESKTOP_UID:$GH_DESKTOP_GID" "$GH_DESKTOP_REPO_ROOT"
  fi
  GH_DESKTOP_REPO_ROOT=$(realpath "$GH_DESKTOP_REPO_ROOT")
  case "$GH_DESKTOP_REPO_ROOT/" in
    "$GH_DESKTOP_HOME"/*) ;;
    *) fail 'the repository directory must be inside the invoking user home' ;;
  esac
  [ "$GH_DESKTOP_REPO_ROOT" != "$GH_DESKTOP_HOME" ] || \
    fail 'choose a code directory below your home, not the whole home directory'
}

require_linuxulator() {
  [ "$(uname -s)" = FreeBSD ] || fail 'this installer must run on FreeBSD'
  [ "$(uname -m)" = amd64 ] || fail 'only amd64 is currently supported'
  [ -x "$CHROOT/bin/bash" ] || fail "Ubuntu chroot not found at $CHROOT"
  [ "$(sysctl -n compat.linux.emul_path)" = "$CHROOT" ] || \
    fail "compat.linux.emul_path must be set to $CHROOT"
  mount -p | awk -v path="$CHROOT/proc" '$2 == path { found = 1 } END { exit !found }' || \
    fail 'Linuxulator mounts are not active; start the Ubuntu service first'
}

as_linux_user() {
  chroot -u "$GH_DESKTOP_UID" -g "$GH_DESKTOP_GID" "$CHROOT" \
    /usr/bin/env \
    "HOME=$LINUX_HOME" \
    "PATH=${NODE_BIN:-/usr/bin}:/usr/bin:/bin" \
    "GH_DESKTOP_APP_DIR=$APP_DIR" \
    "$@"
}

install_linux_dependencies() {
  chroot "$CHROOT" /usr/bin/apt-get update
  chroot "$CHROOT" /usr/bin/apt-get install -y \
    build-essential ca-certificates curl git git-lfs gcc-10 g++-10 python3 xz-utils \
    libasound2 libatspi2.0-0 libdrm2 libgbm1 libgconf-2-4 \
    libgtk-3-0 libgtk-3-dev libnotify4 libnss3 libsecret-1-0 \
    libsecret-1-dev libxss1 libxss-dev libxcb-dri3-0
}

checkout_source() {
  mkdir -p "$CHROOT/opt" "$CHROOT$APP_DIR" \
    "$CHROOT/home/gh-desktop-$GH_DESKTOP_UID"
  chown "$GH_DESKTOP_UID:$GH_DESKTOP_GID" "$CHROOT$APP_DIR"
  chown "$GH_DESKTOP_UID:$GH_DESKTOP_GID" "$CHROOT/home/gh-desktop-$GH_DESKTOP_UID"
  mkdir -p "$CHROOT/home/gh-desktop-$GH_DESKTOP_UID/.runtime"
  chown "$GH_DESKTOP_UID:$GH_DESKTOP_GID" \
    "$CHROOT/home/gh-desktop-$GH_DESKTOP_UID/.runtime"
  chmod 700 "$CHROOT/home/gh-desktop-$GH_DESKTOP_UID/.runtime"

  if [ ! -d "$CHROOT$APP_DIR/.git" ]; then
    chroot -u "$GH_DESKTOP_UID" -g "$GH_DESKTOP_GID" "$CHROOT" \
      /usr/bin/git clone --recurse-submodules --branch "$BRANCH" \
      "$REPOSITORY" "$APP_DIR"
  else
    local_changes=$(as_linux_user /usr/bin/git -C "$APP_DIR" status --porcelain)
    [ -z "$local_changes" ] || fail "source tree has local changes: $CHROOT$APP_DIR"
    as_linux_user /usr/bin/git -C "$APP_DIR" fetch --prune origin "$BRANCH"
    as_linux_user /usr/bin/git -C "$APP_DIR" merge --ff-only FETCH_HEAD
    as_linux_user /usr/bin/git -C "$APP_DIR" submodule update --init --recursive
  fi
}

install_node() {
  node_version=$(sed -n '1p' "$CHROOT$APP_DIR/.node-version")
  case "$node_version" in
    *[!0-9.]*|'') fail "invalid .node-version: $node_version" ;;
  esac

  NODE_HOME="/opt/node-v$node_version-linux-x64"
  NODE_BIN="$NODE_HOME/bin"
  [ -x "$CHROOT$NODE_BIN/node" ] && return

  archive="node-v$node_version-linux-x64.tar.xz"
  checksum_file="$CHROOT/tmp/node-SHASUMS256.txt"
  archive_file="$CHROOT/tmp/$archive"
  fetch -qo "$checksum_file" "https://nodejs.org/dist/v$node_version/SHASUMS256.txt"
  fetch -qo "$archive_file" "https://nodejs.org/dist/v$node_version/$archive"

  expected=$(awk -v file="$archive" '$2 == file { print $1 }' "$checksum_file")
  actual=$(sha256 -q "$archive_file")
  [ -n "$expected" ] && [ "$actual" = "$expected" ] || \
    fail 'Node.js archive checksum verification failed'

  mkdir -p "$CHROOT$NODE_HOME/bin"
  chroot "$CHROOT" /usr/bin/tar -xJf "/tmp/$archive" \
    -C "$NODE_HOME" --strip-components=1
  rm -f "$checksum_file" "$archive_file"

  cat > "$CHROOT$NODE_BIN/yarn" <<EOF
#!/bin/sh
exec $NODE_BIN/node $APP_DIR/vendor/yarn-1.21.1.js "\$@"
EOF
  chmod 755 "$CHROOT$NODE_BIN/yarn"
}

build_application() {
  as_linux_user /usr/bin/env CC=gcc-10 CXX=g++-10 CFLAGS=-Wno-error /bin/sh -c \
    'cd "$GH_DESKTOP_APP_DIR" && yarn install --frozen-lockfile && yarn build:prod'
  [ -x "$CHROOT$APP_DIR/dist/desktop-linux-x64/desktop" ] || \
    fail 'Linux build did not produce dist/desktop-linux-x64/desktop'
}

configure_system_git() {
  git_binary="$CHROOT$APP_DIR/dist/desktop-linux-x64/resources/app/git/bin/git"
  git_core_binary="$CHROOT$APP_DIR/dist/desktop-linux-x64/resources/app/git/libexec/git-core/git"
  [ -f "$git_binary" ] || fail "bundled Git binary not found: $git_binary"
  [ -f "$git_core_binary" ] || fail "bundled Git helper not found: $git_core_binary"
  mv "$git_binary" "$git_binary.bundled"
  ln -s /usr/bin/git "$git_binary"
  mv "$git_core_binary" "$git_core_binary.bundled"
  ln -s /usr/bin/git "$git_core_binary"
}

install_user_config() {
  config_dir="$GH_DESKTOP_HOME/.config"
  mkdir -p "$config_dir"
  printf 'GH_DESKTOP_REPO_ROOT=%s\n' "$GH_DESKTOP_REPO_ROOT" \
    > "$config_dir/gh-desktop-linuxulator.conf"
  chown "$GH_DESKTOP_UID:$GH_DESKTOP_GID" \
    "$config_dir/gh-desktop-linuxulator.conf"
  chmod 600 "$config_dir/gh-desktop-linuxulator.conf"
}

install_browser_bridge() {
  command -v python3 >/dev/null 2>&1 || fail 'host Python 3 is required for browser handoff'
  command -v xdg-open >/dev/null 2>&1 || fail 'host xdg-open is required for browser handoff'
  command -v xdg-mime >/dev/null 2>&1 || fail 'host xdg-mime is required for OAuth callback registration'

  install -d -o root -g wheel -m 755 /usr/local/libexec
  install -o root -g wheel -m 755 \
    "$SCRIPT_DIR/gh-desktop-browser-bridge.py" "$HOST_BROWSER_BRIDGE"
  mkdir -p "$CHROOT/usr/local/bin"
  install -o root -g 0 -m 755 \
    "$SCRIPT_DIR/gh-desktop-browser-bridge.py" \
    "$CHROOT/usr/local/bin/gh-desktop-browser-bridge"

  applications="$CHROOT$LINUX_HOME/.local/share/applications"
  mkdir -p "$applications"
  cat > "$applications/gh-desktop-host-browser.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=FreeBSD Host Browser
Exec=/usr/bin/python3 /usr/local/bin/gh-desktop-browser-bridge --socket /tmp/.gh-desktop-browser-$GH_DESKTOP_UID.sock --open-url %u
Terminal=false
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOF
  chown "$GH_DESKTOP_UID:$GH_DESKTOP_GID" \
    "$applications/gh-desktop-host-browser.desktop"
  chmod 644 "$applications/gh-desktop-host-browser.desktop"

  as_linux_user /usr/bin/env \
    "XDG_CONFIG_HOME=$LINUX_HOME/.config" \
    "XDG_DATA_HOME=$LINUX_HOME/.local/share" \
    /usr/bin/xdg-settings set default-web-browser gh-desktop-host-browser.desktop
  as_linux_user /usr/bin/env \
    "XDG_CONFIG_HOME=$LINUX_HOME/.config" \
    "XDG_DATA_HOME=$LINUX_HOME/.local/share" \
    /usr/bin/xdg-mime default gh-desktop-host-browser.desktop x-scheme-handler/http
  as_linux_user /usr/bin/env \
    "XDG_CONFIG_HOME=$LINUX_HOME/.config" \
    "XDG_DATA_HOME=$LINUX_HOME/.local/share" \
    /usr/bin/xdg-mime default gh-desktop-host-browser.desktop x-scheme-handler/https

  install -d -o root -g wheel -m 755 /usr/local/share/applications
  cat > "$OAUTH_DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=GitHub Desktop OAuth Handler
Exec=/usr/local/bin/python3 $HOST_BROWSER_BRIDGE --socket $CHROOT/tmp/.gh-desktop-oauth-$GH_DESKTOP_UID.sock --open-oauth %u
NoDisplay=true
Terminal=false
MimeType=x-scheme-handler/x-github-client;x-scheme-handler/x-github-desktop-dev-auth;x-scheme-handler/x-github-desktop-auth;
EOF
  chmod 644 "$OAUTH_DESKTOP_FILE"
  sudo -u "$GH_DESKTOP_USER" xdg-mime default \
    "$(basename "$OAUTH_DESKTOP_FILE")" x-scheme-handler/x-github-client
  sudo -u "$GH_DESKTOP_USER" xdg-mime default \
  sudo -u "$GH_DESKTOP_USER" xdg-mime default \
    "$(basename "$OAUTH_DESKTOP_FILE")" x-scheme-handler/x-github-desktop-dev-auth
  sudo -u "$GH_DESKTOP_USER" xdg-mime default \
    "$(basename "$OAUTH_DESKTOP_FILE")" x-scheme-handler/x-github-desktop-auth
}

install_launcher() {
  install -d -o root -g wheel -m 755 /usr/local/libexec /usr/local/share/applications
  install -o root -g wheel -m 755 "$SELF" "$LAUNCHER"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=GitHub Desktop
Comment=GitHub Desktop running through FreeBSD Linuxulator
Exec=$LAUNCHER run %u
Terminal=false
Categories=Development;IDE;
EOF
  chmod 644 "$DESKTOP_FILE"
}

install_app() {
  require_root
  resolve_user
  resolve_repository_root install
  require_linuxulator
  install_linux_dependencies
  checkout_source
  install_node
  build_application
  configure_system_git
  install_user_config
  install_browser_bridge
  install_launcher
  printf 'Installed. Run %s from a terminal or the Applications menu.\n' "$LAUNCHER"
  printf 'Only this host directory is mounted read-write: %s\n' "$GH_DESKTOP_REPO_ROOT"
}

configure_browser_handoff() {
  require_root
  resolve_user
  require_linuxulator
  install_browser_bridge
  install_launcher
  printf 'Configured host browser handoff for %s.\n' "$GH_DESKTOP_USER"
}

run_app() {
  if [ "$(id -u)" -eq 0 ] && [ "${GH_DESKTOP_BROWSER_BRIDGE_ACTIVE:-}" != 1 ]; then
    resolve_user
    resolve_repository_root
    exec sudo -u "$GH_DESKTOP_USER" env \
      "GH_DESKTOP_USER=$GH_DESKTOP_USER" \
      "GH_DESKTOP_REPO_ROOT=$GH_DESKTOP_REPO_ROOT" \
      "DISPLAY=${DISPLAY:-:0}" \
      "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}" \
      "XAUTHORITY=${XAUTHORITY:-}" \
      "$LAUNCHER" run "$@"
  fi

  if [ "$(id -u)" -ne 0 ]; then
    resolve_user
    resolve_repository_root
    [ -x "$HOST_BROWSER_BRIDGE" ] || fail 'run configure-browser to install the browser bridge'
    browser_bridge_socket="$CHROOT/tmp/.gh-desktop-browser-$GH_DESKTOP_UID.sock"
    browser_bridge_pid=
    stop_browser_bridge() {
      if [ -n "$browser_bridge_pid" ]; then
        kill -TERM "$browser_bridge_pid" 2>/dev/null || true
        wait "$browser_bridge_pid" 2>/dev/null || true
      fi
    }
    trap 'stop_browser_bridge' 0
    trap 'exit 1' HUP INT TERM

    if ! python3 "$HOST_BROWSER_BRIDGE" --socket "$browser_bridge_socket" --check; then
      python3 "$HOST_BROWSER_BRIDGE" --socket "$browser_bridge_socket" --serve &
      browser_bridge_pid=$!
      attempts=0
      while ! python3 "$HOST_BROWSER_BRIDGE" --socket "$browser_bridge_socket" --check; do
        kill -0 "$browser_bridge_pid" 2>/dev/null || fail 'browser bridge failed to start'
        attempts=$((attempts + 1))
        [ "$attempts" -lt 50 ] || fail 'timed out starting browser bridge'
        sleep 0.1
      done
    fi

    sudo env \
      "GH_DESKTOP_USER=$GH_DESKTOP_USER" \
      "GH_DESKTOP_REPO_ROOT=$GH_DESKTOP_REPO_ROOT" \
      "GH_DESKTOP_BROWSER_BRIDGE_ACTIVE=1" \
      "DISPLAY=${DISPLAY:-:0}" \
      "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}" \
      "XAUTHORITY=${XAUTHORITY:-}" \
      "$LAUNCHER" run "$@"
    return $?
  fi

  resolve_user
  resolve_repository_root
  require_linuxulator
  binary="$CHROOT$APP_DIR/dist/desktop-linux-x64/desktop"
  [ -x "$binary" ] || fail 'run install to build GitHub Desktop first'

  mount_point="$CHROOT/mnt/gh-desktop-repositories-$GH_DESKTOP_UID"
  mkdir -p "$mount_point"
  if mount -p | awk -v path="$mount_point" '$2 == path { found = 1 } END { exit !found }'; then
    [ "$#" -gt 0 ] || fail "mount point is already in use: $mount_point"
    launch_linux_app "$@"
    return
  fi
  mount -t nullfs "$GH_DESKTOP_REPO_ROOT" "$mount_point"
  oauth_bridge_socket="$CHROOT/tmp/.gh-desktop-oauth-$GH_DESKTOP_UID.sock"
  oauth_bridge_pid=
  stop_oauth_bridge() {
    if [ -n "$oauth_bridge_pid" ]; then
      kill -TERM "$oauth_bridge_pid" 2>/dev/null || true
      wait "$oauth_bridge_pid" 2>/dev/null || true
    fi
    umount "$mount_point" 2>/dev/null || true
  }
  trap 'stop_oauth_bridge' 0
  trap 'exit 1' HUP INT TERM

  "$HOST_BROWSER_BRIDGE" \
    --socket "$oauth_bridge_socket" \
    --serve-oauth \
    --chroot "$CHROOT" \
    --uid "$GH_DESKTOP_UID" \
    --gid "$GH_DESKTOP_GID" \
    --linux-home "$LINUX_HOME" \
    --display "${DISPLAY:-:0}" \
    --dbus-session-bus-address "${DBUS_SESSION_BUS_ADDRESS:-}" \
    --xauthority "${XAUTHORITY:-}" &
  oauth_bridge_pid=$!
  attempts=0
  while ! python3 "$HOST_BROWSER_BRIDGE" --socket "$oauth_bridge_socket" --check; do
    kill -0 "$oauth_bridge_pid" 2>/dev/null || fail 'OAuth callback listener failed to start'
    attempts=$((attempts + 1))
    [ "$attempts" -lt 50 ] || fail 'timed out starting OAuth callback listener'
    sleep 0.1
  done

  launch_linux_app "$@"
}

launch_linux_app() {
  chroot -u "$GH_DESKTOP_UID" -g "$GH_DESKTOP_GID" "$CHROOT" \
    /usr/bin/env \
    "HOME=$LINUX_HOME" \
    "XDG_CONFIG_HOME=$LINUX_HOME/.config" \
    "XDG_CACHE_HOME=$LINUX_HOME/.cache" \
    "XDG_DATA_HOME=$LINUX_HOME/.local/share" \
    "XDG_RUNTIME_DIR=$LINUX_HOME/.runtime" \
    "DISPLAY=${DISPLAY:-:0}" \
    "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}" \
    "GDK_BACKEND=x11" \
    "LOCAL_GIT_DIRECTORY=/usr" \
    "GIT_EXEC_PATH=/usr/lib/git-core" \
    "GIT_CONFIG_SYSTEM=/dev/null" \
    "$APP_DIR/dist/desktop-linux-x64/desktop" --no-sandbox --disable-gpu "$@"
}

SELF=$(realpath "$0")
SCRIPT_DIR=$(dirname "$SELF")
command=${1:-}
[ -n "$command" ] || { usage; exit 2; }
shift

case "$command" in
  install) install_app "$@" ;;
  configure-browser) configure_browser_handoff "$@" ;;
  run) run_app "$@" ;;
  *) usage; exit 2 ;;
esac