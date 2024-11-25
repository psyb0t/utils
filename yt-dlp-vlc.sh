#!/bin/bash

# Check if URL parameter is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <video-url>"
    exit 1
fi

# Define the download directory, log file, and initially set file path to empty
DIR="/tmp/tmp/mp4"
LOGFILE="$DIR/log.txt"
FILE=""

# Create the directory if it doesn't exist
mkdir -p "$DIR"

# Log date and time
echo "Script started on $(date)" >"$LOGFILE"

# Download the video and get the file path
FILE=$(yt-dlp -o "$DIR/video.%(ext)s" "$1" --get-filename 2>&1 | tee -a "$LOGFILE")

# Play the video in VLC
vlc "$FILE" 2>&1 | tee -a "$LOGFILE"

# Remove the video after VLC closes
rm "$FILE" 2>&1 | tee -a "$LOGFILE"

# Log date and time
echo "Script ended on $(date)" >>"$LOGFILE"
