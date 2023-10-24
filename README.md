# Utils

A collection of small utility scripts to make life easier.

## Table of Contents

- [Convert Video to Transparent GIF](#convert-video-to-transparent-gif)
- [SCP Proxy](#scp-proxy)
- [Find File](#find-file)
- [Other Utilities (TBD)](#other-utilities-tbd)

---

## Convert Video to Transparent GIF

### Description

This script converts a given video file to a GIF and makes a specified color transparent. It uses FFmpeg for video conversion and ImageMagick for adding transparency.

### Usage

```bash
./convert-video-to-transparent-gif.sh <video_filename> <transparent_color> [scale_divisor] [framerate]
```

- `<video_filename>`: The name of the video file you want to convert.
- `<transparent_color>`: The color you want to make transparent in the GIF.
- `[scale_divisor]`: Optional. The divisor for the original dimensions of the video (default is 1).
- `[framerate]`: Optional. The framerate for the GIF (default is 10).

### Example

```bash
./convert-video-to-transparent-gif.sh video.mov black 2 15
```

This will create a GIF named `video.gif` with the black color made transparent, dimensions divided by 2, and a framerate of 15.

---

## SCP Proxy

### Description

This script allows you to transfer files to a remote host via an SSH proxy. It first copies the file to the proxy server and then from the proxy to the final destination, cleaning up any temporary files afterward.

### Usage

```bash
./scp-proxy.sh <filepath> <proxy_info> <remote_info> <target_path>
```

- `<filepath>`: The path to the file you want to transfer.
- `<proxy_info>`: The SSH info for the proxy in the format `user@host:port`.
- `<remote_info>`: The SSH info for the remote host in the format `user@host:port`.
- `<target_path>`: The target directory on the remote host where the file will be copied.

### Example

```bash
./scp-proxy.sh myfile.txt user1@proxy.com:22 user2@remote.com:22 /some/remote/directory
```

This will transfer `myfile.txt` to `/some/remote/directory` on `remote.com` via the proxy `proxy.com`.

---

## Find File

### Description

This script allows you to search for a specific file recursively within the current directory and all its subdirectories. It's a handy way to locate files without having to manually dig through directories.

### Usage

```bash
./findfile.sh "<filename>"
```

- `<filename>`: The name or part of the name of the file you're searching for.

### Example

```bash
./findfile.sh "report"
```

In this example, the script will search for any file containing the word "report" in its name starting from the current directory and diving down through all subdirectories.

## Other Utilities (TBD)

More utilities will be added to this repository. Stay tuned!
