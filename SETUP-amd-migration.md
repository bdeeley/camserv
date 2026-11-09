# Migrating Frigate to the AMD box

Target: a server with an onboard AMD (Radeon) iGPU and many CPU cores, once it's
back online. This reuses almost everything from the current NVIDIA setup — same
cameras, same credentials, same exported model — swapping only the pieces that
are GPU-vendor-specific. Background on how the current setup was built is in
`SETUP-this-machine.md`.

## What changes vs. the NVIDIA machine

| | NVIDIA (this machine) | AMD (target machine) |
|---|---|---|
| Image | `frigate:stable-tensorrt` | `frigate:stable-rocm` |
| Decode | NVDEC (`preset-nvidia`) | VAAPI (`preset-vaapi`) |
| Detection | ONNX via CUDA/TensorRT | ONNX via ROCm |
| GPU passthrough | `deploy.resources.reservations.devices` (nvidia driver) | `devices: [/dev/dri, /dev/kfd]` |
| Extra env | — | `LIBVA_DRIVER_NAME=radeonsi`, possibly `HSA_OVERRIDE_GFX_VERSION` |

What does **not** change: `.env` (camera credentials), the camera RTSP paths,
the `config/model_cache/yolov9-s-320.onnx` model file (ONNX is portable — the
same file works on both GPU vendors), and the camera-specific parts of
`config.yml` (go2rtc streams, detect/record resolutions, objects to track).

## Steps

### 1. Copy the whole `camserv/` directory to the new machine

Everything's already prepared:

- `docker-compose.amd.yml` — ready to use as-is.
- `config/config.amd.yml` — ready to use as-is.
- `config/model_cache/yolov9-s-320.onnx` — reuse directly, no rebuild needed.
- `.env` — copy as-is (same cameras, same credentials). `storage/` doesn't need
  to come along unless you want the recording history too.

### 2. Point the active files at the AMD variants

```bash
cd camserv
cp docker-compose.amd.yml docker-compose.yml
cp config/config.amd.yml config/config.yml
```

### 3. Install prerequisites on the AMD box

```bash
sudo apt install -y docker.io docker-compose-plugin   # if not already present
```

No equivalent of the NVIDIA Container Toolkit is needed for AMD — `/dev/dri` and
`/dev/kfd` are passed straight through via the `devices:` list in
`docker-compose.amd.yml`, no special runtime registration required. Confirm the
devices exist on the host first:

```bash
ls -la /dev/dri /dev/kfd
```

If `/dev/kfd` doesn't exist, the ROCm kernel driver isn't loaded — check
`dmesg | grep -i amdgpu` and that the `amdgpu` kernel module is active
(`lsmod | grep amdgpu`).

### 4. Find the GPU's gfx version (may be needed for iGPUs)

AMD doesn't officially support integrated GPUs for ROCm, but most work with an
override. Start the container once, then:

```bash
docker exec -it camserv /opt/rocm/bin/rocminfo | grep gfx
```

The `-rocm` image auto-sets `HSA_OVERRIDE_GFX_VERSION` for known gfx1031
(`10.3.0`) and gfx1103 (`11.0.0`) chips. If your iGPU reports something else and
detection fails or the GPU isn't recognized, uncomment and set
`HSA_OVERRIDE_GFX_VERSION` in `docker-compose.yml`'s `environment:` block to the
matching value (check the ROCm/ONNX Runtime docs for your specific gfx code),
then `docker compose restart`.

### 5. Start it up, with detection disabled first

AMD's docs flag the model-to-MXR conversion step as flaky. Recommended sequence
to avoid a confusing first-run failure:

1. In `config/config.yml`, temporarily set `detect: enabled: false` (top-level,
   or per-camera) for both cameras.
2. `docker compose up -d`
3. Watch the logs for the ONNX model to load and convert/cache:
   `docker logs -f camserv`
4. Once it's loaded cleanly (no errors), re-enable detection — either live in
   the UI, or set `detect: enabled: true` in the config and
   `docker compose restart`.

### 6. Verify GPU usage

AMD doesn't have an `nvidia-smi` equivalent bundled the same way, but you can
confirm the detector process is up and check for GPU-related errors:

```bash
docker logs camserv | grep -iE 'onnx|rocm|vaapi|gfx|error'
docker exec camserv rocm-smi   # if available in the image; shows GPU utilization
```

A healthy startup looks like the NVIDIA one: `ONNX: loading ...`, `ONNX: warming
up detector...`, then `ONNX: ... loaded`, with no tracebacks in between.

### 7. Everything else is unchanged

Cameras, recording, snapshots, retention, and the UI/login flow all work
exactly as documented in `SETUP-this-machine.md` — only the detector/decode
backend is different.

## If ROCm detection just won't cooperate on the iGPU

AMD iGPU support is explicitly best-effort upstream. Fallback options, in order
of preference:

1. Keep VAAPI for decode (`preset-vaapi` — this almost always works on AMD
   iGPUs) but fall back to the **CPU** detector for detection:
   ```yaml
   detectors:
     cpu1:
       type: cpu
       num_threads: 3   # bump this — the target machine has "tons of cores"
   ```
   With a many-core CPU, this is a reasonable fallback — much better than on
   the original machine's limited CPU.
2. Try a smaller/faster exported model (`MODEL_SIZE=t` instead of `s`) if CPU
   inference is too slow — re-run `build-yolo.sh` with that build-arg changed.
