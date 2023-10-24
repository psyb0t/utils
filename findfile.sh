#!/bin/bash

# Check if filename is provided
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 filename"
    exit 1
fi

# Escape spaces in the filename
filename=$(echo "$1" | sed 's/ /\\ /g')

# Search for the file
find . -type f -name "*$filename*"
