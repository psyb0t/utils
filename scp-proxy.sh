#!/bin/bash

# Check if all arguments are provided
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <filepath> <proxy_info> <remote_info> <target_path>"
    exit 1
fi

# Filepath
filepath="$1"
filename="$(basename "$filepath")"

# Parse proxy info
proxy_info="$2"
proxy_user="$(echo "$proxy_info" | cut -d '@' -f 1)"
proxy_host="$(echo "$proxy_info" | cut -d '@' -f 2 | cut -d ':' -f 1)"
proxy_port="$(echo "$proxy_info" | cut -d ':' -f 2)"

# Parse remote info
remote_info="$3"
remote_user="$(echo "$remote_info" | cut -d '@' -f 1)"
remote_host="$(echo "$remote_info" | cut -d '@' -f 2 | cut -d ':' -f 1)"
remote_port="$(echo "$remote_info" | cut -d ':' -f 2)"

# Target path on the remote machine
target_path="$4"

# Temporary file path on the proxy
temp_path="/home/$proxy_user/$filename"

echo "Starting file transfer..."

# Copy file to proxy
echo "Copying file to proxy..."
scp -P "$proxy_port" "$filepath" "$proxy_user@$proxy_host:$temp_path"

# Copy file from proxy to remote host
echo "Copying file from proxy to remote host..."
ssh -A "$proxy_user@$proxy_host" -p "$proxy_port" "scp -P \"$remote_port\" \"$temp_path\" \"$remote_user@$remote_host:$target_path\""

# Remove temporary file from proxy
echo "Removing temporary file from proxy..."
ssh "$proxy_user@$proxy_host" -p "$proxy_port" "rm \"$temp_path\""

echo "File transferred successfully."
