#!/usr/bin/env bash
# Install Screen Cast's machine layer into the user account.
# omarchy plugin add does not run this script.
set -euo pipefail

PLUGIN_ID="fpaulcris.screenmirror"
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
PLUGIN_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

BIN_LINK="${HOME}/.local/bin/screencast"
OLD_Z="${HOME}/.local/bin/screencast-z"
OLD_PY="${HOME}/.local/bin/screenmirror"
UNIT_PATH="${HOME}/.config/systemd/user/screenmirror.service"
DESKTOP_PATH="${HOME}/.local/share/applications/screenmirror.desktop"
ICON_DIR="${HOME}/.local/share/icons/hicolor"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/${PLUGIN_ID}"
RECEIPT="${STATE_DIR}/install.json"
APP_BIN="${PLUGIN_DIR}/zig/zig-out/bin/screencast"

MARKER="screenmirror-plugin-owned: ${PLUGIN_ID}"

die() {
  echo "screenmirror: $*" >&2
  exit 1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

owned_text() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -q "$MARKER\|X-ScreenMirror-Plugin=${PLUGIN_ID}\|ScreenMirror" "$path"
}

our_binary() {
  local target="$1"
  [[ "$target" == "$APP_BIN" || "$target" == "$PLUGIN_DIR/zig/zig-out/bin/screencast-z" || "$target" == "$PLUGIN_DIR/bin/screenmirror" ]]
}

find_zig() {
  if command -v zig >/dev/null 2>&1; then
    command -v zig
    return
  fi
  if [[ -x "${HOME}/.local/share/mise/shims/zig" ]]; then
    echo "${HOME}/.local/share/mise/shims/zig"
    return
  fi
  return 1
}

build_bin() {
  local zig_bin
  zig_bin="$(find_zig)" || die "zig 0.17 is required to build screencast"
  (cd "$PLUGIN_DIR/zig" && "$zig_bin" build -Doptimize=ReleaseFast)
  [[ -x "$APP_BIN" ]] || die "build did not produce $APP_BIN"
}

write_receipt() {
  mkdir -p "$STATE_DIR"
  local tmp first=1 path digest
  tmp="$(mktemp)"
  {
    printf '{\n  "plugin": "fpaulcris.screenmirror",\n  "symlink": "%s",\n  "files": {\n' "$BIN_LINK"
    for path in "$UNIT_PATH" "$DESKTOP_PATH" \
      "${ICON_DIR}/48x48/apps/screencast.png" \
      "${ICON_DIR}/256x256/apps/screencast.png"; do
      [[ -f "$path" && ! -L "$path" ]] || continue
      digest="$(sha256_file "$path")"
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      first=0
      printf '    "%s": "%s"' "$path" "$digest"
    done
    printf '\n  }\n}\n'
  } >"$tmp"
  mv "$tmp" "$RECEIPT"
}

remove_if_recorded() {
  [[ -f "$RECEIPT" ]] || return 0
  local line path digest current
  while IFS= read -r line; do
    path="$(printf '%s\n' "$line" | sed -E 's/^"([^"]+)": "[0-9a-f]{64}"$/\1/')"
    digest="$(printf '%s\n' "$line" | sed -E 's/^"[^"]+": "([0-9a-f]{64})"$/\1/')"
    [[ "$path" == "$HOME"/* ]] || continue
    [[ -f "$path" && ! -L "$path" ]] || continue
    current="$(sha256_file "$path")"
    if [[ "$current" == "$digest" ]]; then
      rm -f "$path"
      echo "removed $path"
    else
      echo "kept $path"
    fi
  done < <(grep -oE '"/[^"]+": "[0-9a-f]{64}"' "$RECEIPT" || true)
}

remove_old_names() {
  local path target
  for path in "$OLD_Z" "$OLD_PY"; do
    if [[ -L "$path" ]]; then
      target="$(readlink -f "$path" || true)"
      if our_binary "$target" || [[ "$target" == "$PLUGIN_DIR"/* ]]; then
        rm -f "$path"
        echo "removed $path"
      fi
    elif [[ -e "$path" && "$path" == "$OLD_Z" ]]; then
      rm -f "$path"
      echo "removed $path"
    fi
  done
}

cmd_uninstall() {
  if [[ -L "$BIN_LINK" ]]; then
    local target
    target="$(readlink -f "$BIN_LINK" || true)"
    if our_binary "$target"; then
      rm -f "$BIN_LINK"
      echo "removed $BIN_LINK"
    else
      echo "kept $BIN_LINK"
    fi
  fi
  remove_old_names
  if systemctl --user is-active --quiet screenmirror.service 2>/dev/null; then
    systemctl --user stop screenmirror.service || true
  fi
  if [[ -f "$RECEIPT" ]]; then
    remove_if_recorded
  else
    if [[ -f "$UNIT_PATH" ]] && grep -q "$MARKER" "$UNIT_PATH"; then
      rm -f "$UNIT_PATH"
      echo "removed $UNIT_PATH"
    fi
    if [[ -f "$DESKTOP_PATH" ]] && grep -q "X-ScreenMirror-Plugin=${PLUGIN_ID}" "$DESKTOP_PATH"; then
      rm -f "$DESKTOP_PATH"
      echo "removed $DESKTOP_PATH"
    fi
  fi
  rm -f "$RECEIPT"
  systemctl --user daemon-reload || true
  echo "Screen Cast machine files removed. The plugin checkout is still there until you run: omarchy plugin remove ${PLUGIN_ID}"
}

cmd_install() {
  build_bin
  if [[ ! -x /usr/bin/gpu-screen-recorder ]]; then
    echo "screenmirror: gpu-screen-recorder is not installed. The stream uses the built-in screen copy." >&2
  fi
  if [[ ! -x /usr/bin/pw-record && ! -x /usr/bin/parecord ]]; then
    echo "screenmirror: neither pw-record nor parecord is installed. The cast will be silent." >&2
  fi
  if ! command -v qrencode >/dev/null; then
    echo "screenmirror: qrencode is optional. The window still shows the address without a QR code." >&2
  fi

  if [[ -e "$BIN_LINK" && ! -L "$BIN_LINK" ]] && ! owned_text "$BIN_LINK"; then
    die "$BIN_LINK already exists and is not Screen Cast"
  fi
  if [[ -e "$UNIT_PATH" ]] && ! owned_text "$UNIT_PATH"; then
    die "$UNIT_PATH already exists and is not Screen Cast"
  fi
  if [[ -e "$DESKTOP_PATH" ]] && ! grep -q "X-ScreenMirror-Plugin=${PLUGIN_ID}" "$DESKTOP_PATH"; then
    die "$DESKTOP_PATH already exists and is not Screen Cast"
  fi

  mkdir -p "${HOME}/.local/bin" "${HOME}/.config/systemd/user" \
    "${HOME}/.local/share/applications" \
    "${ICON_DIR}/scalable/apps" "${ICON_DIR}/48x48/apps" "${ICON_DIR}/256x256/apps"

  remove_old_names
  ln -sfn "$APP_BIN" "$BIN_LINK"

  sed "s|@PLUGIN_DIR@|${PLUGIN_DIR}|g" "$PLUGIN_DIR/share/screenmirror.service" >"$UNIT_PATH"
  cp "$PLUGIN_DIR/share/screenmirror.desktop" "$DESKTOP_PATH"
  rm -f "${ICON_DIR}/scalable/apps/screenmirror.svg" \
    "${ICON_DIR}/48x48/apps/screenmirror.png" \
    "${ICON_DIR}/256x256/apps/screenmirror.png"
  cp "$PLUGIN_DIR/icons/screenmirror-48.png" "${ICON_DIR}/48x48/apps/screencast.png"
  cp "$PLUGIN_DIR/icons/screenmirror-256.png" "${ICON_DIR}/256x256/apps/screencast.png"
  write_receipt

  systemctl --user daemon-reload
  if systemctl --user is-active --quiet screenmirror.service; then
    systemctl --user restart screenmirror.service
    echo "Restarted the running stream so it uses this plugin directory."
  fi
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1 || true
  fi

  echo "Screen Cast command: screencast"
  echo "The TV or phone has to be on the same Wi-Fi as this computer."
  echo "This is a browser address, so it will not show up in the TV's screen-cast menu."
  echo "If the TV browser stays blank, allow inbound TCP 8080, 8000, and 8090 from your private LAN. This installer does not change the firewall."
}

case "${1:-install}" in
  --uninstall|uninstall) cmd_uninstall ;;
  --check|check)
    if find_zig >/dev/null 2>&1; then
      echo "zig: $(find_zig)"
    else
      echo "zig: no"
    fi
    [[ -x /usr/bin/gpu-screen-recorder ]] && echo "gpu-screen-recorder: yes" || echo "gpu-screen-recorder: no (built-in screen copy)"
    if [[ -x /usr/bin/pw-record ]]; then
      echo "pw-record: yes"
    elif [[ -x /usr/bin/parecord ]]; then
      echo "parecord: yes"
    else
      echo "audio: no (silent)"
    fi
    command -v qrencode >/dev/null && echo "qrencode: yes" || echo "qrencode: optional, missing"
    if [[ -x "$APP_BIN" ]]; then
      echo "command: $APP_BIN"
    else
      echo "command: missing"
    fi
    ;;
  install|"") cmd_install ;;
  *)
    die "usage: install.sh [--check|--uninstall]"
    ;;
esac
