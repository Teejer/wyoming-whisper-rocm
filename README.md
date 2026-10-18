# wyoming-whisper-rocm

[Wyoming](https://github.com/rhasspy/wyoming) faster-whisper STT server running
on **AMD GPUs via CTranslate2's official ROCm wheels** — built and measured on
a Ryzen AI 9 HX 370 (Radeon 890M, gfx1150), intended for Home Assistant voice
pipelines.

CTranslate2 merged AMD HIP support in [OpenNMT/CTranslate2#1989](https://github.com/OpenNMT/CTranslate2/pull/1989)
(v4.7.1, Feb 2026). The official release wheels ship GPU kernels for
`gfx1030 gfx1100 gfx1101 gfx1102 gfx1150 gfx1151 gfx1200 gfx1201` — this image
installs that wheel instead of the CUDA-only one from PyPI, and
[wyoming-faster-whisper](https://github.com/OHF-Voice/wyoming-faster-whisper)
runs unmodified on top. No source builds, no forks.

The Docker pattern (ROCm base + official CT2 wheel) follows
[collabora/WhisperLive `docker/Dockerfile.rocm`](https://github.com/collabora/WhisperLive/blob/main/docker/Dockerfile.rocm),
whose approach was verified by AMD staff on gfx1151.

## Requirements

- AMD GPU with CT2 kernel coverage (e.g. Radeon 890M / gfx1150, Strix Halo /
  gfx1151, RDNA3, RDNA4) on a recent kernel with `/dev/kfd` enabled
- Docker + compose. The container carries its own ROCm userspace; the host
  only needs the kernel driver (any current distro kernel works).
- ~30 GB disk for the image (the `rocm/pytorch` base is fat).

## Quick start

```bash
docker compose up -d
docker logs -f whisper-gpu     # wait for "Ready"
```

Home Assistant: **Settings → Devices & Services → Speech-to-text**, add a
Wyoming server pointing at `host:10300`. If you're replacing
`lscr.io/linuxserver/faster-whisper` (or the rhasspy image) on the same port,
stop it first and your existing whisper config entry works unchanged.

Everything is configured with `WYO_WHISPER_*` env vars — see the
[upstream option table](https://github.com/OHF-Voice/wyoming-faster-whisper#environment-variables).
Notable: `WYO_WHISPER_MODEL` (`small.en`, `Systran/faster-whisper-large-v3`, …),
`WYO_WHISPER_HASS_TOKEN_FILE` (biases transcripts toward your entity/area
names — works with `small.en`/`large-v3`, **not** with distil-* models).

## Measured results (HX 370 / Radeon 890M, CT2 4.8.3 ROCm wheel)

Latency = `AudioStop` → `Transcript`, i.e. what you actually wait for in a
voice pipeline. Same-box comparison against a running CPU `base.en` int8
linuxserver deployment.

| Audio | GPU `small.en` fp16 | CPU `base.en` int8 (prior prod) |
|---|---|---|
| 11 s clip | 0.89 s (12.4x RT) | 0.48 s (23x RT) |
| 32 s clip | 2.29 s (14.0x RT) | *see Known issues — CPU mode on this image wedged* |
| 3.5 s command | 1.37 s | 0.44 s |

Read the table honestly: **GPU `small.en` is not lower-latency than CPU
`base.en` — it is a noticeably better model at comparable latency that leaves
the CPU cores free** (transcripts above were byte-identical on clean audio;
`small.en` earns its keep on harder audio and names, which is also what the
`--hass-token` biasing builds on). For short commands either is instant to a
human. The GPU path held 14x realtime sustained on long-form audio with the
GPU, not the CPU, doing the work.

## Known issues (measured, not theoretical)

- **Pin `av<19`.** faster-whisper 1.2.1 calls `av.open(metadata_errors=...)`;
  PyAV 19 removed that kwarg, so an unpinned install fails every request with
  `TypeError`. This image pins `av<19`; remove the pin when upstream fixes it.
- **Do not run `WYO_WHISPER_DEVICE=cpu` on this image.** In testing, CPU int8
  requests through the ROCm CT2 wheel never completed (wedged server-side)
  while GPU requests on the same container ran correctly throughout. GPU is
  the point of this image; for CPU inference use the upstream images.
- **Resource caps matter on APUs.** GPU buffers come from system RAM, and
  containers without `mem_limit` can OOM-kill their way through a shared host
  (this happened during development: a runaway benchmark client, uncapped,
  starved sshd/DNS/Home Assistant on the box). Keep the `mem_limit` / `cpus`
  values or set your own.
- `pip check` may report conflicts inside the `rocm/pytorch` base image
  (torch pins vs the base env). Harmless here; the build gate verifies the
  real requirement — `libctranslate2` is ROCm-linked and contains gfx1150
  kernels — via `ldd`/`strings`.

## How the build works

1. `rocm/pytorch` base (ROCm 7.2.4, Python 3.12).
2. Download `rocm-python-wheels-Linux.zip` from the CT2 GitHub release and
   install the cp312 wheel with `--force-reinstall` **before**
   `wyoming-faster-whisper`, so its `ctranslate2>=4.0` pin is already
   satisfied and pip can't clobber the ROCm wheel with the PyPI CUDA one.
3. `pip install "wyoming-faster-whisper[hass]" "av<19"`.
4. Build-time gate: `ldd` the auditwheel-bundled `libctranslate2` (it lives in
   `ctranslate2.libs/`, not `ctranslate2/lib/`) and require `libamdhip64` +
   gfx1150 strings. A CUDA-only wheel fails the build, not your voice assistant
   at 2 a.m.

## License

MIT (matches wyoming-faster-whisper's). CT2 ROCm wheels are under their own
[license](https://github.com/OpenNMT/CTranslate2/blob/master/LICENSE).
