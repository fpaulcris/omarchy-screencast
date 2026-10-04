#!/usr/bin/env bash
# Install ScreenMirror's machine layer into the user account.
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
UNIT_PATH="${HOME}/.config/systemd/user/screenmirror.service"
DESKTOP_PATH="${HOME}/.local/share/applications/screenmirror.desktop"
ICON_DIR="${HOME}/.local/share/icons/hicolor"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/${PLUGIN_ID}"
RECEIPT="${STATE_DIR}/install.json"

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

write_receipt() {
  mkdir -p "$STATE_DIR"
  python3 - "$RECEIPT" "$BIN_LINK" "$UNIT_PATH" "$DESKTOP_PATH" \
    "${ICON_DIR}/48x48/apps/screencast.png" \
    "${ICON_DIR}/256x256/apps/screencast.png" <<'PY'
import hashlib, json, os, sys
receipt, link, *files = sys.argv[1:]
recorded = {}
for path in files:
    if os.path.isfile(path) and not os.path.islink(path):
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        recorded[path] = digest
json.dump({"plugin": "fpaulcris.screenmirror", "symlink": link, "files": recorded}, open(receipt, "w"), indent=2)
open(receipt, "a").write("\n")
PY
}

remove_if_recorded() {
  python3 - "$RECEIPT" <<'PY'
import hashlib, json, os, sys
receipt = sys.argv[1]
try:
    data = json.load(open(receipt, encoding="utf-8"))
except Exception:
    raise SystemExit(0)
files = data.get("files") or {}
for path, digest in files.items():
    if not isinstance(path, str) or not path.startswith(os.path.expanduser("~") + os.sep):
        print(f"kept {path}")
        continue
    if os.path.islink(path):
        print(f"kept symlink {path}")
        continue
    if not os.path.isfile(path):
        continue
    current = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if current == digest:
        os.remove(path)
        print(f"removed {path}")
    else:
        print(f"kept {path}")
PY
}

cmd_uninstall() {
  if [[ -L "$BIN_LINK" ]]; then
    local target
    target="$(readlink -f "$BIN_LINK" || true)"
    if [[ "$target" == "$PLUGIN_DIR/bin/screenmirror" ]]; then
      rm -f "$BIN_LINK"
      echo "removed $BIN_LINK"
    else
      echo "kept $BIN_LINK"
    fi
  fi
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
  echo "ScreenMirror machine files removed. The plugin checkout is still there until you run: omarchy plugin remove ${PLUGIN_ID}"
}

cmd_install() {
  command -v python3 >/dev/null || die "python3 is required"
  if ! command -v wf-recorder >/dev/null; then
    echo "screenmirror: wf-recorder is not installed. The mirror will not start until you run: omarchy pkg add wf-recorder" >&2
  fi
  if ! command -v qrencode >/dev/null; then
    echo "screenmirror: qrencode is optional. The window still shows the address without a QR code." >&2
  fi

  if [[ -e "$BIN_LINK" && ! -L "$BIN_LINK" ]] && ! owned_text "$BIN_LINK"; then
    die "$BIN_LINK already exists and is not ScreenMirror"
  fi
  if [[ -e "$UNIT_PATH" ]] && ! owned_text "$UNIT_PATH"; then
    die "$UNIT_PATH already exists and is not ScreenMirror"
  fi
  if [[ -e "$DESKTOP_PATH" ]] && ! grep -q "X-ScreenMirror-Plugin=${PLUGIN_ID}" "$DESKTOP_PATH"; then
    die "$DESKTOP_PATH already exists and is not Screen Cast"
  fi

  mkdir -p "${HOME}/.local/bin" "${HOME}/.config/systemd/user" \
    "${HOME}/.local/share/applications" \
    "${ICON_DIR}/scalable/apps" "${ICON_DIR}/48x48/apps" "${ICON_DIR}/256x256/apps"

  rm -f "${HOME}/.local/bin/screenmirror"
  ln -sfn "$PLUGIN_DIR/bin/screenmirror" "$BIN_LINK"
  chmod +x "$PLUGIN_DIR/bin/screenmirror"

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
    command -v python3 >/dev/null && echo "python3: yes" || echo "python3: no"
    command -v wf-recorder >/dev/null && echo "wf-recorder: yes" || echo "wf-recorder: no"
    command -v qrencode >/dev/null && echo "qrencode: yes" || echo "qrencode: optional, missing"
    [[ -x "$PLUGIN_DIR/bin/screenmirror" ]] && echo "command: $PLUGIN_DIR/bin/screenmirror" || echo "command: missing"
    ;;
  install|"") cmd_install ;;
  *)
    die "usage: install.sh [--check|--uninstall]"
    ;;
esac
