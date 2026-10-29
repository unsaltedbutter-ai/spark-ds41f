#!/usr/bin/env bash
# Run on each node with the complete serving cluster stopped.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
readarray -t pin < <(python3 - "$root/config/kernel-trial.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); m=p['memory_saver']
print(m['repository']); print(m['revision']); print(m['version']); print(p['candidate'])
PY
)
test -z "$(docker ps -q --filter name=^dsv41-karmic-kraken$)"
source_dir="$HOME/projects/dgx-spark-memory-saver"
if [ ! -e "$source_dir" ]; then git clone "${pin[0]}" "$source_dir"; fi
test "$(git -C "$source_dir" remote get-url origin)" = "${pin[0]}"
test -z "$(git -C "$source_dir" status --porcelain)"
git -C "$source_dir" fetch origin
git -C "$source_dir" checkout --detach "${pin[1]}"
cd "$source_dir"
./scripts/check
# The signing identity is the memory saver's DGX_MOK_DIR. A site that runs
# fan control reuses the key dgx-spark-fan-control created; a site that does
# not names its own enrolled pair, so the floor is never a prerequisite.
fan_keys=/root/.local/share/dgx-spark-fan-control/keys
saver_keys=/root/.local/share/dgx-spark-memory-saver/keys
if [ -n "${DGX_MOK_DIR:-}" ]; then
  key_dir=$DGX_MOK_DIR
elif sudo test -e "$fan_keys/MOK.der"; then
  key_dir=$fan_keys
else
  key_dir=$saver_keys
fi
if ! sudo test -e "$key_dir/MOK.priv" || ! sudo test -e "$key_dir/MOK.der"; then
  echo "No MOK key pair at $key_dir." >&2
  echo "Create and enroll one (the memory saver's docs/dkms.md), then set" >&2
  echo "DGX_MOK_DIR to its directory. Fan control is not required." >&2
  exit 1
fi
sudo mokutil --test-key "$key_dir/MOK.der" || true
sudo python3 - "$key_dir" <<'PY'
import sys
sys.path.insert(0, 'scripts')
from signing import check_pair, require_enrolled
from pathlib import Path
p=Path(sys.argv[1])
check_pair(p/'MOK.priv', p/'MOK.der'); require_enrolled(p/'MOK.der')
PY
version=${pin[2]}
kernel=${pin[3]}
destination="/usr/src/dgx-spark-memory-saver-$version"
test ! -e "$destination"
# Replace an older registration. Its removal hook restores the stock UVM; its
# source stays in /usr/src, as the memory saver's DKMS guide asks.
for old in $(dkms status -m dgx-spark-memory-saver | sed -n 's|^dgx-spark-memory-saver/\([^,:]*\)[,:].*|\1|p' | sort -u); do
  sudo dkms remove -m dgx-spark-memory-saver -v "$old" --all
done
test -z "$(dkms status -m dgx-spark-memory-saver)"
sudo install -d "$destination/scripts" "$destination/patches" "$destination/packaging"
sudo install -m 0644 dkms.conf compatibility.json provenance.json provenance-610.json "$destination/"
sudo install -m 0755 scripts/driver-build scripts/refresh-initramfs "$destination/scripts/"
sudo install -m 0644 scripts/driver_build.py "$destination/scripts/"
sudo install -m 0644 patches/0001-pack-user-leaf-tables.patch \
  patches/0002-pack-user-leaf-tables-610.patch "$destination/patches/"
sudo install -m 0644 packaging/enable-packing.patch "$destination/packaging/"
sudo dkms add -m dgx-spark-memory-saver -v "$version"
sudo dkms build -m dgx-spark-memory-saver -v "$version" -k "$kernel"
if [ "$(uname -r)" = "$kernel" ] && [ -d /sys/module/nvidia_uvm ]; then
  if sudo fuser /dev/nvidia-uvm; then echo 'Stop GPU clients first' >&2; exit 1; fi
  sudo modprobe -r nvidia_uvm
fi
sudo dkms install -m dgx-spark-memory-saver -v "$version" -k "$kernel"
sudo depmod "$kernel"
sudo update-initramfs -u -k "$kernel"
if [ "$(uname -r)" = "$kernel" ]; then sudo modprobe nvidia_uvm; fi
./scripts/status --json
