#!/bin/bash
set -euo pipefail

usage() { echo 'Usage: ./uninstall.sh [--dry-run]'; }
[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo 'Run this as your normal user; it stages a root-owned uninstaller before privileged execution.' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
dry_run=0
case ${1:-} in
  '') ;;
  --dry-run) dry_run=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
root() {
  if [[ -t 0 ]]; then command sudo "$@";
  elif command -v pkexec >/dev/null 2>&1; then command pkexec "$@";
  else echo 'Need sudo in an interactive terminal or pkexec in a graphical session.' >&2; return 1; fi
}
files=(root-admin.sh payload/razer-alc897-gpio payload/razer-alc897-gpio.service payload/99-razer-alc897-gpio.rules payload/razer-alc897-gpio.sleep)
for f in "${files[@]}"; do [[ -f "$repo/$f" && ! -L "$repo/$f" ]] || { echo "Missing/unsafe project file: $f" >&2; exit 1; }; done
bash -n "$repo/root-admin.sh"
targets=(/usr/local/libexec/razer-alc897-gpio /etc/systemd/system/razer-alc897-gpio.service /etc/udev/rules.d/99-razer-alc897-gpio.rules /etc/systemd/system-sleep/razer-alc897-gpio)
if ((dry_run)); then
  echo 'DRY RUN: no changes made. Removal is allowed only if every installed root-owned file matches this project payload.'
  for f in "${targets[@]}"; do
    if [[ -e "$f" ]]; then echo "Would verify then remove: $f"; else echo "Not present: $f"; fi
  done
  echo 'No service disable is needed: this unit is udev-triggered and is not enabled in a boot target.'
  echo 'Runtime GPIO and audio volume are intentionally left unchanged.'
  exit 0
fi

stage=
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$stage" ]]; then root /usr/bin/rm -rf -- "$stage" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup EXIT
stage=$(root /usr/bin/mktemp -d -- /run/razer-blade14-audio-fix.XXXXXX)
root /usr/bin/install -o root -g root -m 0700 "$repo/root-admin.sh" "$stage/root-admin.sh"
root /usr/bin/install -o root -g root -m 0600 "$repo/payload/razer-alc897-gpio" "$stage/razer-alc897-gpio"
root /usr/bin/install -o root -g root -m 0600 "$repo/payload/razer-alc897-gpio.service" "$stage/razer-alc897-gpio.service"
root /usr/bin/install -o root -g root -m 0600 "$repo/payload/99-razer-alc897-gpio.rules" "$stage/99-razer-alc897-gpio.rules"
root /usr/bin/install -o root -g root -m 0600 "$repo/payload/razer-alc897-gpio.sleep" "$stage/razer-alc897-gpio.sleep"
root "$stage/root-admin.sh" uninstall "$stage"
stage=
