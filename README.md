# Razer Blade 14 (2021) ALC897 headphone GPIO fix

A small, model-specific Linux workaround for the headphone amplifier GPIO setup on **Razer Blade 14 (2021), RZ09-0370** with Realtek **ALC897** and subsystem ID **`1a58:2014`**. It is not intended as a generic Realtek fix.

## Why this exists

The [upstream Linux patch proposal](https://patchew.org/linux/20260417-for-next-v1-1-c3338f3b1f5d@gmail.com/) says this board's headphone output uses a GPIO-controlled external amplifier. Its proposed fix enables GPIO 0–2 as outputs and drives them high. The commands implemented here follow that patch's three writes to codec NID `0x01`:

- GPIO mask: verb `0x716`, value `0x07`
- GPIO direction: verb `0x717`, value `0x07`
- GPIO data: verb `0x715`, value `0x07`

The helper first reads mask/direction/data using GET verbs. It only writes when the values are not already `0x07`, then reads them back. If a write or verification fails, it attempts to restore the values it read before writing.

## Hardware match and activation

The helper scans `/proc/asound/card*/codec#*` for **both** codec vendor ID `0x10ec0897` and subsystem ID `0x1a582014`. It derives the card and codec address from the matching procfs path and maps that to `/dev/snd/hwC<card>D<codec-address>`; it does not assume the card is `card1`.

After installation:

- A udev rule requests a one-shot systemd service when an HDA codec-address-0 hwdep device appears. The helper performs the exact hardware-ID check before any write.
- A systemd-sleep hook invokes the same helper after resume.
- The service is **udev-triggered**, not enabled in a boot target. It does not restart PipeWire/WirePlumber or alter the default sink, profile, or volume.

## Requirements and installation

- Bash, systemd, udev, and `hda-verb` from `alsa-tools`.
- The scripts do not install packages or compile a kernel.
- Run as your normal user; the installer stages its privileged helper/payload in a root-owned mode-0700 directory before executing the staged root-owned installer. It uses `sudo` in an interactive terminal or `pkexec` when no terminal is available.

```sh
./install.sh --dry-run
./install.sh
```

Installation refuses to overwrite existing target files or matching backups. Installed helper, unit, rule, and sleep hook are root-owned and not writable by ordinary users. The installer validates shell syntax, the systemd unit, and the udev match, then runs the installed helper twice to check its idempotent path. No reboot or sleep cycle is performed by the installer.

## Uninstall and restoring the GPIO state

```sh
./uninstall.sh --dry-run
./uninstall.sh
```

Uninstall only removes the four root-owned files if each still exactly matches this project. The unit is udev-triggered, so there is no boot-target enablement to disable. Uninstall does **not** change live GPIO values, profile, default sink, or volume; the running hardware state lasts until the codec is reset or the machine reboots.

To manually restore an earlier GPIO snapshot, first read and save the current values with GET verbs (`0xf16` mask, `0xf17` direction, `0xf15` data), then write back those saved values. On the reported RZ09-0370 test machine the pre-fix values were all zero; restoring that specific snapshot disables the headphone amplifier and will likely remove headphone output:

```sh
sudo hda-verb /dev/snd/hwC1D0 0x01 0x715 0x00  # data
sudo hda-verb /dev/snd/hwC1D0 0x01 0x717 0x00  # direction
sudo hda-verb /dev/snd/hwC1D0 0x01 0x716 0x00  # mask
```

The example device node is for illustration only; discover the matching codec and hwdep node rather than assuming its card number. Do not restore zeros if your saved values differ.

## Reported result and limitations

On one RZ09-0370 / ALC897 / `1a58:2014` machine, the owner manually applied the three GPIO writes and reported that headphone sound returned. The installed helper was then run through systemd and read back `0x07/0x07/0x07`; the helper's repeated run was an idempotent no-op. **A real cold boot and suspend/resume cycle have not been tested**, so automatic reapplication across those transitions remains unverified on that machine.

The upstream patch describes the disabled amplifier as causing roughly 15 dB lower output and degraded frequency response. Enabling it can therefore make audio substantially louder without changing the software volume slider. Start at a low listening level and take care after boot/resume. This workaround changes codec GPIO registers only; it does not promise a fix for other symptoms or hardware revisions.

## Provenance and licensing

The GPIO sequence is attributed to the upstream patch proposal linked above. This project has no `LICENSE` file: the applicable license for the patch-derived sequence and this repository's helper/installer has not been established here. Contact the relevant authors before redistributing under a chosen license.
