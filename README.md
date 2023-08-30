# utils

A collection of small utility scripts to make life easier.

## Table of Contents

- [Convert Video to Transparent GIF](#convert-video-to-transparent-gif)
- [Other Utilities (TBD)](#other-utilities-tbd)

---

## Convert Video to Transparent GIF

### Description

This script converts a given video file to a GIF and makes a specified color transparent. It uses FFmpeg for video conversion and ImageMagick for adding transparency.

### Usage

```
./convert-video-to-transparent-gif.sh <video_filename> <transparent_color>
```

- `<video_filename>`: The name of the video file you want to convert.
- `<transparent_color>`: The color you want to make transparent in the GIF.

### Example

```
./convert-video-to-transparent-gif.sh video.mov black
```

This will create a GIF named `video.gif` with the black color made transparent.

---

## Other Utilities (TBD)

More utilities will be added to this repository. Stay tuned!
