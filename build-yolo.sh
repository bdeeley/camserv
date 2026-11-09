#!/bin/bash
set -e
cd /tmp
docker build . --build-arg MODEL_SIZE=s --build-arg IMG_SIZE=320 --output /home/bdeeley/camserv/config/model_cache -f- > /home/bdeeley/camserv/build.log 2>&1 <<'EOF'
FROM python:3.11 AS build
RUN apt-get update && apt-get install -y git libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
ARG MODEL_SIZE
ARG IMG_SIZE
RUN git clone --depth 1 https://github.com/WongKinYiu/yolov9.git /yolov9
WORKDIR /yolov9
RUN pip install --no-cache-dir torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir -r requirements.txt onnx onnxruntime onnx-simplifier
RUN wget -q -O yolov9-${MODEL_SIZE}.pt https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${MODEL_SIZE}-converted.pt
RUN python3 export.py --weights yolov9-${MODEL_SIZE}.pt --imgsz ${IMG_SIZE} --simplify --include onnx
FROM scratch AS export
ARG MODEL_SIZE
ARG IMG_SIZE
COPY --from=build /yolov9/yolov9-${MODEL_SIZE}.onnx /yolov9-${MODEL_SIZE}-${IMG_SIZE}.onnx
EOF
echo "EXIT CODE: $?" >> /home/bdeeley/camserv/build.log
