# Utils

A collection of small utility scripts to make life easier.

## Table of Contents

- [Convert Video to Transparent GIF](#convert-video-to-transparent-gif)
- [SCP Proxy](#scp-proxy)
- [Other Utilities (TBD)](#other-utilities-tbd)

---

## Convert Video to Transparent GIF

### Description

This script converts a given video file to a GIF and makes a specified color transparent. It uses FFmpeg for video conversion and ImageMagick for adding transparency.

### Usage

```
./convert-video-to-transparent-gif.sh <video_filename> <transparent_color> [scale_divisor] [framerate]
```

- `<video_filename>`: The name of the video file you want to convert.
- `<transparent_color>`: The color you want to make transparent in the GIF.
- `[scale_divisor]`: Optional. The divisor for the original dimensions of the video (default is 1).
- `[framerate]`: Optional. The framerate for the GIF (default is 10).

### Example

```
./convert-video-to-transparent-gif.sh video.mov black 2 15
```

This will create a GIF named `video.gif` with the black color made transparent, dimensions divided by 2, and a framerate of 15.

---

## SCP Proxy

### Description

This script allows you to transfer files to a remote host via an SSH proxy. It first copies the file to the proxy server and then from the proxy to the final destination, cleaning up any temporary files afterward.

### Usage

```
./scp-proxy.sh <filepath> <proxy_info> <remote_info> <target_path>
```

- `<filepath>`: The path to the file you want to transfer.
- `<proxy_info>`: The SSH info for the proxy in the format `user@host:port`.
- `<remote_info>`: The SSH info for the remote host in the format `user@host:port`.
- `<target_path>`: The target directory on the remote host where the file will be copied.

### Example

```
./scp-proxy.sh myfile.txt user1@proxy.com:22 user2@remote.com:22 /some/remote/directory
```

This will transfer `myfile.txt` to `/some/remote/directory` on `remote.com` via the proxy `proxy.com`.

---

## Other Utilities (TBD)

More utilities will be added to this repository. Stay tuned!
