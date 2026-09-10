# Notes: reviving a GeForce 315M (GT218) on a 2026 kernel

Background for the patches in this repo. Hardware: a 2011 Toshiba Satellite
L735 laptop, Intel i7-2620M, GeForce 315M (GT218, Tesla architecture,
compute capability 1.2, 16 CUDA cores). Currently running as a small
always-on server (Nextcloud + Postgres + Redis in Docker), not a desktop.

## Starting point: nouveau's clock floor

By default `nouveau` runs this GPU at its lowest power state permanently —
405 MHz core / 810 MHz shader / 405 MHz memory — because NVIDIA never
documented the register interface for automatic clock management on this
generation, and nouveau's reverse-engineered "reclocking" support is opt-in
and explicitly marked experimental.

Forcing the high pstate by hand
(`/sys/kernel/debug/dri/<pci-id>/pstate`, writing `0f`) does raise core and
shader to their maximum (606 MHz / 1468 MHz) without issue. Also forcing the
*memory* clock to its high state (790 MHz) reliably produces:

```
BUG: scheduling while atomic: kworker/2:0/.../0x00000002
Workqueue: events nvkm_pstate_work [nouveau]
gt215_ram_calc+... gt215_link_train.isra.0+...
```

— a real bug in nouveau's GT215-family memory-retraining code, not something
fixable from outside the kernel tree. The practical fix is the boot
parameter `nouveau.config=NvMemExec=0`, which disables memory reclocking
specifically while leaving core/shader reclocking alone, plus a small
systemd oneshot service that writes the high pstate on every boot. That gets
you ~80% of the card's rated performance with zero risk — see
`nouveau-pstate.service` if you'd rather stop here than deal with the
proprietary driver at all.

## Why go further: the legacy proprietary driver

NVIDIA's last driver release supporting this GPU family is **340.108**,
frozen since 2019 and never updated for kernels released after it — the
opposite problem from most abandoned software: the codebase is fixed in
2013-era kernel APIs while the kernel keeps moving. Kernel *downgrades*
improve compatibility here; kernel upgrades make it worse. On this exact
kernel (6.17), the most actively maintained fork
([dkosmari/nvidia-340.108-updated](https://github.com/dkosmari/nvidia-340.108-updated))
still failed outright — see the main [README](README.md) for the four build
errors and the fifth, runtime-only bug it doesn't cover.

## Chasing the EVO crash

Getting the module to build (`patches/0001`–`0004`) was necessary but not
sufficient. `Xorg` would load, detect the GPU, then fail:

```
NVIDIA(GPU-0): EVO Push buffer channel allocation failed
NVIDIA(GPU-0): Failed to allocate EVO core DMA push buffer
```

The investigation ruled out, in order: IOMMU/DMA remapping (`intel_iommu=off`
made zero difference once tested cleanly), MSI vs. legacy INTx interrupts
(`NVreg_EnableMSI=0`, no difference), Plymouth/splash holding the console,
`vt7`/`-novtswitch`/`-seat`/`-auth` arguments, and boot-time race conditions.

The actual cause turned out to be upstream of any of that: `/proc/driver/nvidia`
being left behind by an unclean unload meant `nvidia_init_module()` was
aborting at the *procfs registration* step, before the GPU was ever properly
probed — `NVRM: No NVIDIA graphics adapter probed!`. Once probing succeeds,
downstream code that expects a live GPU (including the display engine init
that produces the EVO error) fails in whatever way happens to come first.
Nouveau's own `core notifier timeout` on the same hardware, seen while
testing whether letting nouveau initialize the card first would help, was
the same category of symptom from the opposite driver.

The fix is `patches/0005`. Verified reproducible: same kernel, same
hardware, `already registered` + `EVO Push buffer channel allocation
failed` every time before the patch, clean module reload and successful
mode-set every time after.

## The GLX crash — and getting past it anyway

Even with the kernel module fully working, `nvidia_drv.so` (Xorg's
closed-source driver blob) would crash: a segfault inside
`libnvidia-glcore.so.340.108` a few seconds after mode-set in some runs,
`*** stack smashing detected ***` inside `dlopen("libglx.so", ...)` in
others. The driver's own startup warning explains why the ABI mismatch
exists in the first place:

```
This server has a video driver ABI version of 25.2 that this
driver does not officially support.
```

Xorg's video-driver ABI has moved from what 340.108 targeted (~2014) to 25.2
today; `-ignoreABI` disables the version *check*, not the actual
incompatibility, and the two different crash signatures across otherwise
identical runs (varying with ASLR) are consistent with real memory
corruption rather than one deterministic bug. There's no source to patch —
but a `gdb`-caught backtrace of the second crash showed it happening inside
`dlopen()` specifically while loading the GLX module, which raised the
question of what happens if that code path is never entered at all.

Disabling GLX in `xorg.conf` (`Section "Module" / Disable "glx"`) turned out
to be enough for `Xorg` itself to stop crashing and run stably — confirmed
with `xclock` actually rendering on the physical display, not just the log
looking clean. But a real desktop session still crashed immediately,
`xfce4-session` this time, `SIGABRT` from `__stack_chk_fail`. A backtrace
pointed at the *identical* root cause reached from a completely different
direction:

```
epoxy_has_glx (libepoxy.so.0)
gdk_display_manager_open_display (libgdk-3.so.0)
gtk_init_with_args (libgtk-3.so.0)
main (xfce4-session)
```

GTK3 doesn't ask Xorg whether GLX is available — every GTK3 app calls
`epoxy_has_glx()` on startup itself, which `dlopen()`s the GL libraries
directly, completely bypassing whatever Xorg has disabled. Since
`xfce4-session`, `xfwm4`, `xfce4-panel`, `Thunar`, and `xfdesktop` are all
GTK3, a normal desktop launches half a dozen processes that would each
independently walk straight back into the same corruption.

GDK checks an environment variable before doing any of that probing:
`GDK_GL=disable`. With that set for the session and GLX disabled in
`xorg.conf`, a full Xfce desktop came up and stayed up — confirmed on real
hardware, not just process list: `xfce4-session`, `xfwm4`, `xfce4-panel`,
`Thunar`, and `xfdesktop` all alive, panel and desktop icons visibly
rendering, GPU sitting at its idle `P12` state throughout since there's no
GL work happening. No 3D acceleration, obviously — but a stable, ordinary
2D desktop on the actual NVIDIA driver, not `nouveau`.

That held up until the next clean reboot, when `xfwm4` itself turned out to
still be crashing — `GDK_GL` only stops probing that goes through *GDK's*
`gdk_display_manager_open_display()`; the window manager calls
`epoxy_has_glx()` directly for its own compositor-capability check, a
different call path GDK's env var never touches:

```
dlopen (libc.so.6)
epoxy_has_glx (libepoxy.so.0)
n/a (xfwm4)
main (xfwm4)
```

Same crash, same root cause, reached a third way — which meant the actual
fix couldn't live at the per-application layer at all. It had to be *what
`libGL.so.1` resolves to*, system-wide, since that's the one thing every one
of these call paths shares.

That's where it got interesting: `/usr/lib/x86_64-linux-gnu/libGL.so.1` —
Mesa's file, still owned by the `libgl1` package according to `dpkg -S` —
didn't exist on disk anymore. The 340.108 installer doesn't just add its own
copy, it **deletes** Mesa's, presumably because it predates glvnd (the
mechanism that lets an NVIDIA driver and Mesa's implementation coexist on
the same system) and its installer logic assumes it's the only GL provider
around to manage. `apt-get install --reinstall libgl1` gets Mesa's file
back — but simply removing NVIDIA's colliding symlinks at `/usr/lib/libGL.so`
and `/usr/lib/libGL.so.1` didn't stick: **`ldconfig` recreates them**. It
scans every `.so*` file in its trusted directories (`/lib`, `/usr/lib`, and
whatever `/etc/ld.so.conf.d/*.conf` lists), reads each one's embedded
SONAME, and (re)creates the matching bare-SONAME symlink if one's missing —
so as long as NVIDIA's actual `libGL.so.340.108` sat in `/usr/lib` declaring
itself as `libGL.so.1`, the very next `ldconfig` run (including the one
`dpkg`/`apt` trigger automatically) put the broken symlink right back,
regardless of what got deleted by hand a moment earlier.

The fix that actually holds: move `libGL.so.340.108` itself out of any
directory `ldconfig` scans (`extras/fix-libgl-crash.sh` moves it to
`/opt/nvidia-legacy-gl-disabled/`, nothing deleted), then `ldconfig` again.
With nothing left claiming the `libGL.so.1` SONAME except Mesa's restored
file, `epoxy_has_glx()` — called from GDK, from `xfwm4` directly, from
anywhere — resolves to a completely ordinary, correctly-built library and
just... works. `GDK_GL=disable` turned out to be unnecessary once this was
fixed: confirmed by removing it from `.xinitrc` and rebooting — full desktop,
`xfwm4` included, zero crashes, without a single per-application workaround.
Nothing else this driver provides (`nvidia-smi`, the kernel module, the
CUDA driver API) touches `libGL.so.1` at all, so none of it was affected by
any of this.

## The screen locker crashing (unrelated to the driver)

Once the desktop was stable, one more thing turned out to be broken:
`light-locker` (XFCE's default screen locker on this distro) was dying on
every launch, `SIGTRAP`, so the screen never actually locked — idle timeout
or the manual "Lock" action both did nothing. `coredumpctl` traced it to a
deliberate `g_error()` inside `gs_monitor_new()`, disassembled straight to
its format string:

```
Environment variable XDG_SESSION_PATH not set. Is LightDM running?
```

`light-locker` is, as its own name and package description say, built
specifically for LightDM: it reads `XDG_SESSION_PATH` to talk to LightDM's
D-Bus session interface for the actual lock/unlock handoff, and treats that
variable being unset as a fatal condition (`g_error()` is always fatal in
glib — it raises `SIGTRAP` via `G_BREAKPOINT`, not just a warning). This
machine was never running LightDM or any display manager at all — the whole
setup here is deliberately `tty1` autologin + `startx` (see the reboot/
autologin work above), so that variable was never going to be set, on any
boot, no matter what.

Fix: swap it for `xfce4-screensaver` — XFCE's own screensaver/locker,
which doesn't assume any particular display manager and talks to Xorg and
the session directly. `apt purge light-locker light-locker-settings &&
apt install xfce4-screensaver` was the whole change; XFCE's `xflock4`
dispatch script already tries `xfce4-screensaver-command` before any of the
other lockers it knows about, and `xfce4-screensaver` ships its own
`/etc/xdg/autostart` entry, so no session/autostart configuration needed
changing at all. Confirmed across a clean reboot: `xfce4-screensaver`
autostarts, `xfce4-screensaver-command --lock` actually locks (queried
active, process stays alive, zero coredumps) and `--deactivate` actually
unlocks.

## Headless: what actually works, and how fast

With no X in the picture, the kernel module is solid: `nvidia-smi`,
persistence mode, `nvidia-modprobe`, and the CUDA *driver* API
(`libcuda.so`) all work normally.

`nvcc` itself dropped code generation for compute capability 1.x in CUDA
7.0 (2015) — there's no compiler left, of any vintage still available for
download, that targets this hardware directly. The only way to run code on
it now is to write PTX by hand and JIT-compile it at load time via
`cuModuleLoadDataEx()`. Two things were built this way to get real,
measured numbers instead of estimates:

**Raw FP32 throughput** (`fma_bench.ptx`, a tight `mad.f32` loop): the GPU
saturates at **~17.4 GFLOPS** once thread count exceeds what its 16 cores
can hide launch overhead for — more threads beyond that point don't move
the number, confirming it's a real hardware ceiling, not a measurement
artifact. The same laptop's CPU (i7-2620M, 4 threads, AVX) does **~24–25
GFLOPS** on an equivalent multiply-add loop. No FP16 or INT8 units exist on
this silicon at all, so quantized-inference speedups that matter on modern
GPUs don't apply here regardless.

**A real model, end to end**: [llama2.c](https://github.com/karpathy/llama2.c)'s
`matmul()` — the only operation that matters for its runtime — was replaced
with a call into a hand-written PTX kernel, uploading the checkpoint's
weights to VRAM once and only transferring the small activation vector per
layer. Output text is byte-identical to the stock CPU build at temperature
0 (correctness check passed), running Karpathy's `stories15M` checkpoint:

| | tok/s |
|---|---|
| CPU (4 threads, OpenMP) | 165.5 |
| GPU (GT218, custom PTX kernel) | 19.7 |

The gap is larger than the raw-GFLOPS ratio alone would suggest, because a
forward pass issues ~55 separate kernel launches (9 matmuls × 6 layers +
final classifier), and per-launch driver overhead on 2013-era tooling isn't
free. Consistent with everything above: the GPU runs the workload
correctly, just slower than the CPU sitting next to it — which is expected
of a 16-core, FP32-only part from 2010 doing anything at all in 2026.
