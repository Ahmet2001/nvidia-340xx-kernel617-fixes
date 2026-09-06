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

## The wall that's still there

Even with the kernel module fully working, `nvidia_drv.so` (Xorg's
closed-source driver blob) segfaults a few seconds after a successful
mode-set, every time, regardless of how `X` is invoked. `coredumpctl`
confirms the fault is inside `libnvidia-glcore.so.340.108`. The driver's own
startup warning explains why:

```
This server has a video driver ABI version of 25.2 that this
driver does not officially support.
```

Xorg's video-driver ABI has moved from what 340.108 targeted (~2014) to 25.2
today; `-ignoreABI` disables the version *check*, not the actual
incompatibility. There's no source to patch here — this is as far as a
kernel-side fix can take you. If you need X, use `nouveau` (see above).

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
