#!/bin/bash

# Check if the required arguments were provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <video_filename> <transparent_color>"
    exit 1
fi

# Extract the filename without the extension
filename=$(basename -- "$1")
filename="${filename%.*}"

# Convert the video to a GIF using FFmpeg
ffmpeg -i "$1" -vf "scale=iw/1:ih/1" -r 10 "${filename}.gif"

# Make the GIF transparent using ImageMagick and overwrite the original GIF
convert "${filename}.gif" -transparent "$2" "${filename}.gif"

echo "Done. Updated ${filename}.gif with transparency."
