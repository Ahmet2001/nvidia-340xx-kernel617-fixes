# nvidia-340xx-kernel617-fixes

Patches that get NVIDIA's last legacy driver for Tesla-generation GPUs
(**340.108**, the final release supporting cards like the GeForce 8/9/100–300
series) building and *reloading* cleanly on modern kernels — verified
through **Linux 6.17** — plus a config workaround that gets you an actual
stable desktop out of it, GLX crash and all (see
[below](#the-x11glx-crash-and-how-to-get-a-working-desktop-anyway)).

This sits on top of [dkosmari/nvidia-340.108-updated](https://github.com/dkosmari/nvidia-340.108-updated),
which already patches the driver source for kernels 6.0+ but still fails to
build or hangs the GPU on recent kernels. These patches close that gap —
and along the way turned up a genuine signature mismatch inside NVIDIA's
own source between two files that happened to never get cross-checked by
the compiler (see `0006` below).

## The problem

On a modern kernel (tested: Linux Mint 22.3 / Ubuntu 24.04, kernel
6.17.0-22-generic), `dkosmari/nvidia-340.108-updated` fails to build:

```
nv-dma.c:58:6: error: no previous prototype for 'nv_destroy_dma_map_scatterlist' [-Werror=missing-prototypes]
nv-drm.c:41:16: fatal error: drm/drm_legacy.h: No such file or directory
nv.c:2471:5: error: implicit declaration of function 'del_timer_sync' [-Werror=implicit-function-declaration]
make[4]: *** No rule to make target 'nv-kernel.o', needed by 'nvidia.o'.  Stop.
```

Patching around all four gets you a module that *builds* — but the first time
you unload and reload it (or just reboot with it already loaded), the GPU
stops working:

```
WARNING: CPU: 2 PID: 4059 at fs/proc/generic.c:402 proc_register+0x17c/0x220
proc_dir_entry 'driver/nvidia' already registered
...
NVRM: failed to register procfs!
NVRM: No NVIDIA graphics adapter probed!
```

Nobody had published a fix for that last one — it's a real bug in the
driver's own procfs teardown path, not a kernel API removal, so no amount of
"port the API rename" patching touches it. It's what turned into hours of
debugging in this project before we traced it: nouveau's own `EVO Push
buffer channel allocation failed` crash on the same hardware was in fact a
downstream symptom of this exact bug (see [Background](#background) below).

## What's here

| Patch | Fixes |
|---|---|
| `0001-Kbuild-*.patch` | The kbuild `%_shipped` auto-copy rule removed from recent kernel build scripts, which `nv-kernel.o` (the precompiled resource-manager blob) depends on |
| `0002-nvidia-config-*.patch` | Disables `nv-drm.c`'s legacy AGP/`drm_legacy_pci_init()` registration path, which pulls in `<drm/drm_legacy.h>` — a header removed from the kernel once DRM's legacy AGP support was dropped. Not needed on PCI Express cards. |
| `0003-nv-rename-*.patch` | `del_timer_sync()` → `timer_delete_sync()` (renamed in-tree) |
| `0004-nv-dma-*.patch` | Marks two internally-only-used functions `static` instead of suppressing the warning globally |
| `0005-nv-procfs-*.patch` | **The real fix.** `nv_unregister_procfs()` could be called without actually removing `/proc/driver/nvidia` cleanly, and `nv_register_procfs()` never allowed for that stale entry existing on the next load. Every load after the first hit the kernel's `proc_register()` WARN, aborted `nvidia_init_module()` immediately, and the GPU never probed. The patch removes the stale subtree and retries once, and clears the module-global pointer on unregister so a second unregister can't act on it either. |
| `0006-fix-remaining-*.patch` | The rest of `-Wmissing-prototypes`/`-declarations`, fixed per-function instead of suppressed: six functions only ever used within their own file get marked `static`; two (`nvidia_init_module`/`nvidia_exit_module`) get a proper prototype in `nv-proto.h` since they're genuinely called across files. Along the way this surfaces a real bug in NVIDIA's own source: `nv-frontend.c` carried a stale `extern` for `nv_procfs_unregister_all()` declared with **one** parameter, while `nv-procfs.c` defines it with **two** — invisible to the compiler because they're different translation units, and never triggered because `nv-frontend.c` doesn't actually call it. The patch adds the correct two-argument prototype to `nv-proto.h` and drops the stale declaration. |
| `0007-fix-noop-debug-macros-*.patch` | Four debug-print macros expand to nothing in non-`DEBUG` builds, which is where `-Wempty-body` came from (an `if (...) UVM_DBG_PRINT_RL(...);` with no braces becomes an empty-bodied `if`). Fixed at the source — `do { } while (0)` instead of nothing — which also closes off a dangling-`else` hazard for every other unbraced use of these macros in the ~1000-line file they're used throughout, not just the one call site the warning happened to point at. |

With all seven applied, the driver builds under the **original, unmodified
`-Werror`** — no warning classes are suppressed anywhere in the tree.

## Usage

```bash
git clone https://github.com/dkosmari/nvidia-340.108-updated.git
cd nvidia-340.108-updated
./apply-patch.sh          # downloads NVIDIA's installer, applies dkosmari's own patch

# apply these on top
for p in /path/to/nvidia-340xx-kernel617-fixes/patches/*.patch; do
    patch -p1 < "$p"
done

sudo make install         # dkms add/build/install
```

Or just run [`install.sh`](install.sh) from a clone of this repo, which does
all of the above.

**Before loading the driver**, make sure `nouveau` isn't holding the card:

```bash
sudo modprobe -r nouveau
sudo modprobe nvidia
sudo nvidia-modprobe        # creates /dev/nvidia* if needed
nvidia-smi
```

The module now survives repeated `rmmod`/`modprobe` cycles and reboots
without the procfs registration failing.

## The X11/GLX crash, and how to get a working desktop anyway

The **X11 display driver** (`nvidia_drv.so`, the closed-source blob shipped
in NVIDIA's `.run` installer) crashes on current Xorg server ABIs (tested:
Xorg 21.1, ABI 25.2) as soon as anything touches its GLX code — a segfault
inside `libnvidia-glcore.so.340.108`, or `*** stack smashing detected ***`
inside `dlopen("libglx.so", ...)`, depending on run. Both point at the same
root cause: this driver's GLX code was built against a ~2014 video-driver
ABI, and current Xorg has moved on far enough that touching it corrupts
memory. That's binary-only code with no source available, so it's not
fixable directly — but it turns out to be fully avoidable, and the result is
a normal, stable desktop with no GL/3D acceleration:

1. **Disable GLX in Xorg itself** — add to `xorg.conf`:
   ```
   Section "Module"
       Disable "glx"
   EndSection
   ```
2. **Stop GTK3 apps from probing it independently.** Disabling GLX in Xorg
   isn't enough on its own: `xfce4-session`, `xfwm4`, `xfce4-panel`, and
   every other GTK3 app call `epoxy_has_glx()` (via GDK) on startup
   regardless of what Xorg has disabled, which `dlopen()`s the GL libraries
   and hits the exact same corruption. Set:
   ```
   export GDK_GL=disable
   ```
   before starting your session (`.xprofile`, wherever `startxfce4` gets
   launched from, etc.).

With both in place: **confirmed working on real hardware** — full Xfce
session (`xfce4-session`, `xfwm4`, `xfce4-panel`, `Thunar`, `xfdesktop`) up
and stable, GPU idling normally with no GL load. See
[`extras/xorg.conf.no-glx`](extras/xorg.conf.no-glx) for a complete,
annotated config.

No amount of `-ignoreABI`, VT, `-seat`/`-auth` arguments, or plymouth/
display-manager configuration *around* the crash changed anything (all of
that was tried first and ruled out — see [Background](#background)); the
GLX code path itself is what needed to be avoided entirely, not worked
around procedurally.

For headless/compute use (no X at all), the kernel module alone is enough:

- `nvidia-smi` — full status, persistence mode, forces the GPU to its `P0`
  performance state on demand
- The CUDA **driver API** (`libcuda.so`) — confirmed with a hand-written PTX
  kernel (`nvcc` itself dropped code generation for this hardware's compute
  capability, 1.2, back in CUDA 7.0, so there's no compiler left that
  targets it — PTX loaded through `cuModuleLoadDataEx` at runtime is the only
  way left in)

If you specifically need GL/3D acceleration (this driver can't give you
that on current Xorg, GLX or not), `nouveau` with manual reclocking
(`nouveau.config=NvMemExec=0`, forcing the high `pstate` via
`/sys/kernel/debug/dri/*/pstate`) gets you working core/shader clocks, at
the cost of memory clock staying at its low-power state (raising it
triggers a separate, unrelated nouveau kernel bug on this GPU family). A
systemd unit for that, [`extras/nouveau-pstate.service`](extras/nouveau-pstate.service),
is included, along with
[`extras/nvidia-persistence.service`](extras/nvidia-persistence.service) for
keeping this driver's GPU at `P0` across reboots in the headless/compute
case above.

## Background

Written up while getting a 2011 Toshiba Satellite laptop (GeForce 315M /
GT218, Tesla architecture) off `nouveau`'s power-saving clock floor. Full
story, including the reclocking side-quest and the GFLOPS/tokens-per-second
measurements that came out of it, is in [`NOTES.md`](NOTES.md).

## Verified on

- Linux Mint 22.3 (Ubuntu 24.04 base), kernel `6.17.0-22-generic`
- GeForce 315M (GT218, compute capability 1.2)
- NVIDIA driver 340.108, applied on top of dkosmari/nvidia-340.108-updated

Should apply cleanly to any Tesla-generation card using the same driver on a
6.x kernel; the procfs bug in particular is generic to the driver, not
GPU-specific.

## License

The patches in this repository are original work, released under the MIT
license (see [`LICENSE`](LICENSE)). They modify NVIDIA's proprietary driver
source, which is not redistributed here — `apply-patch.sh` (from the
upstream repo) downloads it directly from NVIDIA.
