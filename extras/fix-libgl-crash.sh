#!/bin/bash
# Fixes the root cause of nvidia_drv.so/libepoxy crashing on current Xorg:
# the 340.108 installer (which predates glvnd) overwrites the system's
# libGL.so.1 with its own ABI-incompatible build, and *removes* Mesa's
# original file from the multiarch directory rather than coexisting with it
# the way a glvnd-aware installer would. Any code that dlopen()s libGL.so.1
# -- Xorg's own GLX extension when Xorg loads it, or libepoxy's
# epoxy_has_glx() that GTK3 apps (window managers, panels, file managers)
# call on startup regardless of what Xorg has disabled -- ends up touching
# NVIDIA's broken blob and corrupts memory (segfault, or "stack smashing
# detected", depending on where in the load it happens to land).
#
# This restores Mesa's libGL.so.1 as the *only* thing that soname resolves
# to, system-wide. Nothing else this driver provides (nvidia-smi, the
# kernel module, the CUDA driver API) touches libGL.so.1 at all, so nothing
# else is affected.
#
# You still need "Disable \"glx\"" in xorg.conf's Module section -- that's
# a *separate* file (Xorg's own GLX extension module, not the client-side
# libGL.so.1 this script fixes) that's still NVIDIA's broken build. This
# script plus that xorg.conf change is the complete fix; once both are in
# place, GDK_GL=disable is *not* needed (GTK3 apps resolve to Mesa now,
# which fails GLX detection cleanly instead of crashing).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

echo "==> Reinstalling libgl1 to restore Mesa's multiarch libGL.so.1"
apt-get install --reinstall -y libgl1

DISABLED_DIR=/opt/nvidia-legacy-gl-disabled
mkdir -p "$DISABLED_DIR"

echo "==> Moving NVIDIA's colliding libGL.so.1 out of ldconfig's search path"
# ldconfig auto-creates a "libGL.so.1" symlink for *any* .so file in a
# scanned directory whose embedded SONAME is libGL.so.1 -- so removing just
# the symlink isn't enough as long as the real file (libGL.so.<version>)
# is still sitting in /usr/lib; ldconfig recreates it on the next run.
# Moving the real file out of any scanned directory is what actually works.
shopt -s nullglob
for f in /usr/lib/libGL.so /usr/lib/libGL.so.1 /usr/lib/libGL.so.[0-9]*; do
    echo "    $f"
    mv -f "$f" "$DISABLED_DIR/"
done
shopt -u nullglob

echo "==> Rebuilding the linker cache"
ldconfig

echo
echo "==> Result:"
ldconfig -p | grep 'libGL\.so\.1\b' || echo "    (nothing registered -- unexpected, check manually)"

echo
echo "Done. NVIDIA's original file(s), if any were found, are preserved in"
echo "$DISABLED_DIR for reference; nothing was deleted."
