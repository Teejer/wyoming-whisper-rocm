# Wyoming faster-whisper on AMD ROCm GPUs (CTranslate2 official ROCm wheel).
# Target: gfx1150 (Ryzen AI 300 / Radeon 890M) and friends — CT2 ROCm wheels
# ship kernels gfx803..gfx1201 including gfx1150/gfx1151.
#
# Reference recipe: collabora/WhisperLive docker/Dockerfile.rocm (merged PR #523),
# verified by AMD staff on ROCm 7.2.x. CT2 keeps the name "cuda" for ROCm.
#
# NOTE: pip install ctranslate2 from PyPI is CUDA-only — the ROCm wheel must be
# installed FIRST so faster-whisper's `ctranslate2>=4.0` pin is already satisfied
# and pip does not clobber it with the CUDA wheel.

FROM rocm/pytorch:rocm7.2.4_ubuntu24.04_py3.12_pytorch_release_2.10.0

ARG CT2_VERSION=4.8.3

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends curl unzip binutils && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -sL "https://github.com/OpenNMT/CTranslate2/releases/download/v${CT2_VERSION}/rocm-python-wheels-Linux.zip" -o /tmp/ct2.zip && \
    unzip -j /tmp/ct2.zip 'temp-linux/ctranslate2-*-cp312-cp312-manylinux*x86_64*.whl' -d /tmp && \
    pip install --no-cache-dir --force-reinstall /tmp/ctranslate2-*-cp312-*.whl && \
    rm -f /tmp/ct2.zip /tmp/ctranslate2-*.whl

# faster-whisper 1.2.1 pins av>=11 but PyAV 19 removed av.open(metadata_errors=)
# that faster-whisper calls -> TypeError on every request. Pin below 19.
RUN pip install --no-cache-dir "wyoming-faster-whisper[hass]" "av<19" && \
    pip check || echo "WARN: pip check reported issues (common in fat ROCm images; the ldd check below is the real gate)"

# Hard gate: the imported libctranslate2 must be ROCm-linked (the PyPI wheel
# links libcuda/libcublas instead). Works without GPU access at build time.
# Note: auditwheel ships the lib under a hashed name in ../ctranslate2.libs/,
# not as ctranslate2/lib/libctranslate2.so — glob for it instead of assuming.
RUN L=$(python -c "import ctranslate2,os,glob;d=os.path.dirname(ctranslate2.__file__);print(glob.glob(os.path.join(d,'..','ctranslate2.libs','libctranslate2*.so*'))[0])") && \
    ldd "$L" | grep -q libamdhip64 && \
    strings "$L" | grep -q gfx1150 && echo "OK: ROCm-linked libctranslate2 with gfx1150 kernels" || \
    { echo "FATAL: libctranslate2 is not ROCm-linked / lacks gfx1150"; ldd "$L"; exit 1; }

# Defaults as ENV, not CMD args: wyoming-faster-whisper gives argv precedence
# over WYO_WHISPER_* env vars, so baked-in args could never be overridden from
# compose. ENV defaults can.
ENV HF_HOME=/data \
    XDG_CACHE_HOME=/data/cache \
    MODELSCOPE_CACHE=/data/modelscope \
    WYO_WHISPER_URI=tcp://0.0.0.0:10300 \
    WYO_WHISPER_DATA_DIR=/data \
    WYO_WHISPER_LANGUAGE=en \
    WYO_WHISPER_DEVICE=cuda \
    WYO_WHISPER_COMPUTE_TYPE=float16 \
    WYO_WHISPER_MODEL=small.en

EXPOSE 10300

HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
    CMD python -m wyoming_faster_whisper.health_check || exit 1

ENTRYPOINT ["python", "-m", "wyoming_faster_whisper"]
