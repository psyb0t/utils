#!/bin/bash
sudo apt install v4l2loopback-dkms

sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="VirtualCam" exclusive_caps=1


while true; do
    for file in *.mp4; do
        ffmpeg -re -i "$file" -vf "scale=1920:1080,format=yuv420p" -f v4l2 /dev/video10
    done
done
