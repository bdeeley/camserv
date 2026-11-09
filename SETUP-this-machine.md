# Frigate setup on this machine (NVIDIA RTX 5080)

What this is: a record of exactly how this Frigate instance was built, so it can be
reproduced, debugged, or ported later. For the AMD migration, see
`SETUP-amd-migration.md`.

## Hardware / environment

- Host: Debian 13 (trixie), 20 cores, 62GB RAM
- GPU: NVIDIA GeForce RTX 5080 (Blackwell), driver 610.43.02, CUDA 13.3
- Cameras: 2x Reolink RLC-520A (5MP, 2560x1920 main stream, 640x480 sub stream),
  RTSP on port 554, found via `nmap -p 554,8000,9000 --open -T4 <subnet>/24`
  (reverse DNS showed hostnames `deeleycam1.deeleymotorsports.lan` /
  `deeleycam2.deeleymotorsports.lan`)
- No git repo — this is just a working directory with compose/config files.

## 1. Install the NVIDIA Container Toolkit

Docker needs the `nvidia` runtime to pass the GPU through to the container.

```bash
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify: `docker info | grep -i runtime` should list `nvidia` alongside `runc`.

## 2. Directory layout

```
camserv/
├── docker-compose.yml       # active compose file (currently = docker-compose.nvidia.yml)
├── docker-compose.nvidia.yml
├── docker-compose.amd.yml   # for the future AMD box
├── .env                     # camera credentials (chmod 600, not committed anywhere)
├── config/
│   ├── config.yml            # active Frigate config (currently = config.nvidia.yml)
│   ├── config.nvidia.yml
│   ├── config.amd.yml        # for the future AMD box
│   └── model_cache/
│       └── yolov9-s-320.onnx # exported detection model (portable across NVIDIA/AMD)
├── storage/                  # recordings (bind-mounted to /media/frigate)
├── build-yolo.sh             # script that exports the ONNX model (see step 5)
└── build.log                 # output of the last model build
```

## 3. Camera credentials and discovery

Cameras were found by scanning the LAN:

```bash
nmap -p 554,8000,9000 --open -T4 172.16.0.0/24
```

Credentials (old ZoneMinder install had crashed and the password was lost) were
recovered by the user remembering them — no brute force was needed. They live in
`.env`:

```
FRIGATE_CAM_USER=bdeeley
FRIGATE_CAM_PASS=<redacted>
FRIGATE_CAM1_IP=172.16.0.113
FRIGATE_CAM2_IP=172.16.0.15
```

Verified the RTSP paths and resolutions with `ffmpeg`/`ffprobe` (installed via
`sudo apt install -y ffmpeg`) before trusting them in the Frigate config:

```bash
ffprobe -v error -rtsp_transport tcp \
  "rtsp://$USER:$PASS@<ip>:554/h264Preview_01_main" \
  -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1
```

Reolink RLC-520A paths: `h264Preview_01_main` (2560x1920, h264/aac) and
`h264Preview_01_sub` (640x480, h264/aac, 10fps).

## 4. docker-compose.yml

Key points vs. the stock Frigate template:

- Image: `ghcr.io/blakeblackshear/frigate:stable-tensorrt` — needed for the ONNX
  detector to auto-select the CUDA/TensorRT execution provider.
- GPU passed through via a `deploy.resources.reservations.devices` block
  (`driver: nvidia`), which requires the container toolkit from step 1.
- `env_file: .env` to keep camera credentials out of the compose file.
- Bind mounts for `./config` and `./storage` instead of `/path/to/your/...`
  placeholders.

## 5. Object detection: exporting a YOLOv9 ONNX model

Frigate's ONNX detector needs a model file — none is bundled in the image. We
exported YOLOv9-s at 320px via a throwaway Docker build (clones the YOLOv9 repo,
installs deps, downloads pretrained weights, runs the export script, and copies
just the resulting `.onnx` file out via a `FROM scratch` export stage — nothing
from that build ends up in the Frigate image or container).

The script is `build-yolo.sh`. Run it with:

```bash
bash build-yolo.sh
```

It writes to `config/model_cache/yolov9-s-320.onnx` and logs everything to
`build.log`.

### Problems hit and fixed along the way

1. **PyTorch 2.6+ `weights_only` default change.** `torch.load()` now defaults to
   `weights_only=True`, which refuses to unpickle the YOLOv9 checkpoint (a full
   pickled model object, not just a state dict). Fix: pin `torch==2.5.1` /
   `torchvision==0.20.1` (CPU wheels) *before* installing the repo's
   `requirements.txt`, so the unpinned `torch>=1.7.0` constraint in that file
   doesn't pull a newer version.
2. **Output directory ownership.** An earlier failed build run left
   `config/model_cache/` owned by `root:root`, so BuildKit's client-side file
   export failed with "permission denied" even though the export inside the
   build succeeded. Fix: `sudo chown bdeeley:bdeeley config/model_cache`.

Once the model file exists, BuildKit's cache makes re-running `build-yolo.sh`
with a different `MODEL_SIZE` (`t`/`s`/`m`/`c`/`e`) nearly instant for everything
except the final export step.

## 6. Frigate config.yml — detector + model section

```yaml
detectors:
  onnx:
    type: onnx

model:
  model_type: yolo-generic
  width: 320
  height: 320
  input_tensor: nchw
  input_dtype: float
  path: /config/model_cache/yolov9-s-320.onnx
  labelmap_path: /labelmap/coco-80.txt

ffmpeg:
  hwaccel_args: preset-nvidia # NVDEC decode
```

On the `-tensorrt` image, the `onnx` detector auto-detects and uses the GPU — no
extra config needed. Confirmed working by checking `docker exec camserv
nvidia-smi`, which shows a `frigate.detector:onnx` process using GPU memory
alongside the two per-camera `ffmpeg` decode processes.

## 7. Cameras

Each camera's low-res substream is used for `detect` (matches `config.yml`'s
`width/height`), and the full-res main stream is used for `record`. go2rtc
restreams each camera once so both roles share a single RTSP connection to the
camera instead of opening it twice.

## 8. Starting / restarting

```bash
docker compose up -d       # first start, or after editing docker-compose.yml
docker compose restart     # after editing config/config.yml (NOT hot-reloaded)
docker logs camserv        # check status
```

`docker compose up -d` does **not** restart an already-running container just
because `config.yml` changed — only compose-file changes trigger that. Use
`docker compose restart` (or `docker restart camserv`) for config edits.

## 9. First-login credentials

Frigate auto-creates an `admin` user with a random password on first start,
printed once in the logs:

```bash
docker logs camserv 2>&1 | grep -A2 "Created a default user"
```

Change it immediately under Settings → Users in the UI
(`https://localhost:8971`, self-signed cert).

## Verifying everything is working

```bash
# GPU decode + detection both active:
docker exec camserv nvidia-smi
# Expect to see 2x ffmpeg processes (decode) + 1x frigate.detector:onnx (detection)

# No errors in recent logs:
docker logs camserv --tail 100 | grep -iE 'error|fail|traceback'
```
