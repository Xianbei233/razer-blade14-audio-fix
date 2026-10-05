#!/bin/bash
set -euo pipefail

usage() { echo 'Usage: ./install.sh [--dry-run]'; }
[[ ${EUID:-$(id -u)} -ne 0 ]] || { echo 'Run this as your normal user; it stages a root-owned installer before privileged execution.' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
dry_run=0
case ${1:-} in
  '') ;;
  --dry-run) dry_run=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

root() {
  if [[ -t 0 ]]; then
    command sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    command pkexec "$@"
  else
    echo 'Need sudo in an interactive terminal or pkexec in a graphical session.' >&2
    return 1
  fi
}

files=(root-admin.sh payload/razer-alc897-gpio payload/razer-alc897-gpio.service payload/99-razer-alc897-gpio.rules payload/razer-alc897-gpio.sleep)
for f in "${files[@]}"; do
  [[ -f "$repo/$f" && ! -L "$repo/$f" ]] || { echo "Missing/unsafe project file: $f" >&2; exit 1; }
done
for f in root-admin.sh install.sh uninstall.sh payload/razer-alc897-gpio payload/razer-alc897-gpio.sleep; do
  bash -n "$repo/$f"
done
command -v hda-verb >/dev/null || { echo 'hda-verb missing; install alsa-tools first (this script installs no packages).' >&2; exit 1; }

# Read-only exact hardware preflight. The card number is discovered from procfs, never assumed.
matched=()
shopt -s nullglob
for codec in /proc/asound/card[0-9]*/codec#*; do
  grep -Eiq '^[[:space:]]*Vendor Id:[[:space:]]*0x10ec0897[[:space:]]*$' "$codec" || continue
  grep -Eiq '^[[:space:]]*Subsystem Id:[[:space:]]*0x1a582014[[:space:]]*$' "$codec" || continue
  matched+=("$codec")
done
((${#matched[@]} == 1)) || { echo "Expected exactly one ALC897/1a582014 codec, found ${#matched[@]}; refusing." >&2; exit 1; }
codec=${matched[0]}
[[ "$codec" =~ /card([0-9]+)/codec#([0-9]+)$ ]] || exit 1
hwdep="/dev/snd/hwC${BASH_REMATCH[1]}D${BASH_REMATCH[2]}"
[[ -c "$hwdep" ]] || { echo "Matching codec has no hwdep node: $hwdep" >&2; exit 1; }
printf 'Matched %s -> %s\n' "$codec" "$hwdep"

targets=(/usr/local/libexec/razer-alc897-gpio /etc/systemd/system/razer-alc897-gpio.service /etc/udev/rules.d/99-razer-alc897-gpio.rules /etc/systemd/system-sleep/razer-alc897-gpio)
if ((dry_run)); then
  echo 'DRY RUN: no files/services/hardware changed.'
  echo 'Privileged installer will refuse any pre-existing target or same-name backup.'
  printf 'Would install root-owned files:\n'; printf '  %s\n' "${targets[@]}"
  echo 'The root-owned helper will be executed via a oneshot systemd unit after install.'
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
root "$stage/root-admin.sh" install "$stage"
stage= # root admin removes its private staging directory on exit
