#!/bin/bash

# Check for prefix arg
if [ -z "$1" ]; then
    echo "Usage: $0 <prefix>"
    echo "Example: $0 goblin/"
    exit 1
fi

PREFIX="$1"

echo "[*] Searching for images starting with prefix: $PREFIX"

IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^$PREFIX")

if [ -z "$IMAGES" ]; then
    echo "[*] No images found with prefix '$PREFIX'."
    exit 0
fi

echo "[*] The following images will be removed:"
echo "$IMAGES"
echo

read -p "Proceed with deletion? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "[*] Aborted."
    exit 0
fi

echo "$IMAGES" | xargs -r docker rmi

echo "[*] Done."
