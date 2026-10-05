#!/bin/bash
# This file is copied to a root-only /run directory before execution.
set -euo pipefail
shopt -s nullglob

fail() { printf 'razer-blade14-audio-fix: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'must be run as root from the root-owned staging copy'
mode=${1:-}
stage=${2:-}
[[ "$stage" == /run/razer-blade14-audio-fix.* ]] || fail 'invalid staging path'
[[ -d "$stage" && ! -L "$stage" ]] || fail 'staging directory missing or is a symlink'
[[ $(/usr/bin/stat -c %u "$stage") == 0 && $(/usr/bin/stat -c %a "$stage") == 700 ]] || fail 'staging directory must be root-owned mode 0700'
[[ ! -L "$0" && $(/usr/bin/stat -c %u "$0") == 0 && $(/usr/bin/stat -c %a "$0") == 700 ]] || fail 'root admin must be a root-owned mode-0700 regular file'

payloads=(razer-alc897-gpio razer-alc897-gpio.service 99-razer-alc897-gpio.rules razer-alc897-gpio.sleep)
for name in "${payloads[@]}"; do
  p="$stage/$name"
  [[ -f "$p" && ! -L "$p" && $(/usr/bin/stat -c %u "$p") == 0 ]] || fail "unsafe/missing staged payload: $name"
done
helper=/usr/local/libexec/razer-alc897-gpio
unit=/etc/systemd/system/razer-alc897-gpio.service
rule=/etc/udev/rules.d/99-razer-alc897-gpio.rules
hook=/etc/systemd/system-sleep/razer-alc897-gpio
files=("$helper" "$unit" "$rule" "$hook")
transaction=0

rollback_install() {
  /usr/bin/rm -f -- "${files[@]}"
  /usr/bin/systemctl daemon-reload || true
  /usr/bin/udevadm control --reload-rules || true
}
cleanup() {
  local rc=$?
  trap - EXIT
  if ((transaction)); then rollback_install; fi
  /usr/bin/rm -rf -- "$stage"
  exit "$rc"
}
trap cleanup EXIT

require_root_dir() {
  local d=$1
  if [[ -L "$d" ]]; then fail "refusing symlink directory: $d"; fi
  if [[ -e "$d" ]]; then
    [[ -d "$d" && $(/usr/bin/stat -c %u "$d") == 0 ]] || fail "unsafe directory: $d"
  else
    /usr/bin/install -d -o root -g root -m 0755 "$d"
  fi
}

find_target_hwdep() {
  local f card addr
  local -a matches=()
  for f in /proc/asound/card[0-9]*/codec#*; do
    [[ -r "$f" ]] || continue
    /usr/bin/grep -Eiq '^[[:space:]]*Vendor Id:[[:space:]]*0x10ec0897[[:space:]]*$' "$f" || continue
    /usr/bin/grep -Eiq '^[[:space:]]*Subsystem Id:[[:space:]]*0x1a582014[[:space:]]*$' "$f" || continue
    if [[ "$f" =~ ^/proc/asound/card([0-9]+)/codec#([0-9]+)$ ]]; then
      matches+=("${BASH_REMATCH[1]}:${BASH_REMATCH[2]}")
    fi
  done
  ((${#matches[@]} == 1)) || fail "expected exactly one matching ALC897/1a582014 codec; found ${#matches[@]}"
  IFS=: read -r card addr <<<"${matches[0]}"
  target="/dev/snd/hwC${card}D${addr}"
  [[ -c "$target" ]] || fail "matching codec found but hwdep node is unavailable: $target"
  printf '%s\n' "$target"
}

if [[ "$mode" == install ]]; then
  [[ -x /usr/bin/hda-verb ]] || fail 'hda-verb missing; install alsa-tools first'
  target=$(find_target_hwdep)
  /usr/bin/bash -n "$stage/razer-alc897-gpio"
  /usr/bin/bash -n "$stage/razer-alc897-gpio.sleep"

  for f in "${files[@]}"; do
    [[ ! -e "$f" && ! -L "$f" ]] || fail "refusing to overwrite existing path: $f"
    for backup in "$f".bak*; do [[ ! -e "$backup" ]] || fail "refusing: backup exists: $backup"; done
  done

  require_root_dir /usr/local
  require_root_dir /usr/local/libexec
  require_root_dir /etc/systemd
  require_root_dir /etc/systemd/system
  require_root_dir /etc/systemd/system-sleep
  require_root_dir /etc/udev
  require_root_dir /etc/udev/rules.d

  transaction=1
  /usr/bin/install -o root -g root -m 0755 "$stage/razer-alc897-gpio" "$helper"
  /usr/bin/install -o root -g root -m 0644 "$stage/razer-alc897-gpio.service" "$unit"
  /usr/bin/install -o root -g root -m 0644 "$stage/99-razer-alc897-gpio.rules" "$rule"
  /usr/bin/install -o root -g root -m 0755 "$stage/razer-alc897-gpio.sleep" "$hook"

  if ! /usr/bin/systemd-analyze verify "$unit"; then
    fail 'systemd unit verification failed; installed files rolled back'
  fi
  /usr/bin/systemctl daemon-reload
  /usr/bin/udevadm control --reload-rules

  udev_out=$(/usr/bin/udevadm test "/sys/class/sound/$(basename "$target")" 2>&1) || {
    fail 'udev test failed; installed files rolled back'
  }
  printf '%s\n' "$udev_out" | /usr/bin/grep -Fq 'SYSTEMD_WANTS=razer-alc897-gpio.service' || fail 'udev test did not request the service; installed files rolled back'
  if ! /usr/bin/systemctl start razer-alc897-gpio.service || ! /usr/bin/systemctl start razer-alc897-gpio.service; then
    fail 'service execution failed; installed files rolled back (helper attempts hardware rollback on write failure)'
  fi
  [[ $(/usr/bin/systemctl show razer-alc897-gpio.service -p Result --value) == success ]] || {
    fail 'systemd service result was not success; installed files rolled back'
  }
  transaction=0
  printf 'Installed; udev matched %s; service ran twice successfully.\n' "$target"
  /usr/bin/stat -c '%n %U:%G %a' "${files[@]}"
elif [[ "$mode" == uninstall ]]; then
  present=0
  for f in "${files[@]}"; do
    if [[ -e "$f" || -L "$f" ]]; then ((present+=1)); fi
  done
  if ((present == 0)); then echo 'No installed files found; nothing to remove.'; exit 0; fi
  ((present == ${#files[@]})) || fail 'partial installation detected; refusing incomplete removal'
  for i in "${!files[@]}"; do
    f=${files[$i]}; staged="$stage/${payloads[$i]}"
    [[ -f "$f" && ! -L "$f" && $(/usr/bin/stat -c %u "$f") == 0 ]] || fail "unsafe installed file: $f"
    /usr/bin/cmp -s -- "$f" "$staged" || fail "installed file differs from project payload; refusing removal: $f"
  done
  # This service is udev-triggered, not enabled in a boot target; stop only, do not disable.
  /usr/bin/systemctl stop razer-alc897-gpio.service
  /usr/bin/rm -f -- "${files[@]}"
  /usr/bin/systemctl daemon-reload
  /usr/bin/udevadm control --reload-rules
  echo 'Removed the four matching root-owned project files. Live GPIO and audio volume were not changed.'
else
  fail 'usage: root-admin.sh {install|uninstall} ROOT_OWNED_STAGE'
fi
