# warp-confield

Preservation of the in-browser Flash promo that warprecords.com served in April 2001 to announce Autechre's album *Confield*. The artifact has not been reachable on the open web for many years; this repository keeps it playable, alongside the tooling and provenance needed to reproduce, verify, and extend the preservation work.

This is not a product. It is a small archive. Treat it the way you would treat a recovered floppy disk.

## What is here

```
warp-confield/
|-- README.md
|-- LICENSE                       Anti-Capitalist Software License v1.4 (covers the original code in this repo)
|-- NOTICE                        Provenance and copyright statement for preserved third-party material
|-- .gitignore
|-- original/
|   |-- conflashpin.swf           The recovered Flash 4 SWF, byte-identical to the Wayback snapshot
|   |-- confield.html             The HTML embed page that loaded the SWF on warprecords.com
|-- web/
|   |-- confield.html             Single-file Ruffle wrapper. Open in any modern browser.
|   |-- offline-bundle/
|       |-- index.html            Same wrapper, but loads Ruffle from local files (no CDN)
|       |-- capture.html          Chrome-free render surface used for the headless screen capture
|       |-- conflashpin.swf       Copy of the recovered SWF
|       |-- ruffle/               Ruffle web nightly build, dated 2026-04-30
|       |-- start.command         Double-click on macOS/Linux to spin up a local server
|-- video/
|   |-- confield_promo.mp4        Visual render through Ruffle + the released album track underneath
|-- tools/
|   |-- sck_record.swift          Source for the macOS ScreenCaptureKit recording CLI
```

## How to play it

Pick whichever fits your situation:

- **Easiest** - open `web/confield.html` in any modern browser. The SWF is base64-embedded; Ruffle is loaded from the unpkg CDN on first open.
- **Fully offline** - serve `web/offline-bundle/` over a local web server (the included `start.command` does this on macOS/Linux), then open `index.html`.
- **Watch a fixed render** - play `video/confield_promo.mp4` in any video player. See NOTICE for what is and is not original about the audio in this file.
- **Native Flash player** - feed `original/conflashpin.swf` to Ruffle desktop or any Flash 4-compatible player.

## What was recovered, and what was lost

The Flash promo is a small loader (`conflashpin.swf`, 135360 bytes, Flash 4, stage 308x230 @ 12 fps, 2300 frames). On startup it streams two external SWFs containing the audio:

```
http://www.warprecords.com/confield/audio1.swf
http://www.warprecords.com/confield/audio2.swf
```

Neither audio SWF was ever captured. The Wayback Machine has exactly one snapshot of each, both from 2012-02-02, and both are HTTP 403 responses - the Internet Archive crawler reached the URLs but the server returned forbidden. Verification:

```sh
curl -s "https://web.archive.org/cdx/search/cdx?url=warprecords.com/confield/audio1.swf&output=text"
curl -s "https://web.archive.org/cdx/search/cdx?url=warprecords.com/confield/audio2.swf&output=text"
```

The `conflashpin.swf` itself contains zero sound tags (no `DefineSound`, no `SoundStreamHead`, no `StartSound`); the audio was always external and is now gone from the open web.

`video/confield_promo.mp4` substitutes the released album track *VI Scose Poise* (track 1 of *Confield*, Warp WARP CD 102, 2001) under the recovered visuals, as the closest available stand-in. See NOTICE.

If you find an authentic copy of `audio1.swf` or `audio2.swf`, please open an issue.

## Reproducing the work

### Recovering the SWF from Wayback

```sh
curl -L "https://web.archive.org/web/20010414031825id_/http://www.warprecords.com/confield/conflashpin.swf" -o conflashpin.swf
```

The `id_` flag in the Wayback URL serves the asset raw, without the player's wrapper or rewrites.

### Building the screen-capture tool

`tools/sck_record.swift` is a small ScreenCaptureKit + AVAssetWriter CLI for macOS 13+. It captures a region or a specific window to MP4 with H.264 video and AAC audio. Build:

```sh
swiftc -O -o sck_record tools/sck_record.swift
```

Usage:

```
sck_record <out.mp4> <seconds> <x> <y> <w> <h>          # capture a display rect (points)
sck_record <out.mp4> <seconds> --app <substring>        # capture a window owned by an app whose name matches
sck_record <out.mp4> <seconds> --app <substring> --hide # ...and hide the source app right after start
sck_record --list                                        # list candidate windows
```

### Reproducing the muxed video

The exact pipeline used to produce `video/confield_promo.mp4`, end to end:

```sh
# 1. Place the SWF inside Ruffle desktop's sandbox container so it loads without filesystem prompts.
mkdir -p "$HOME/Library/Containers/rs.ruffle.ruffle/Data/Documents"
cp original/conflashpin.swf "$HOME/Library/Containers/rs.ruffle.ruffle/Data/Documents/"

# 2. Launch Ruffle desktop in the background (download from https://ruffle.rs).
ruffle --width 616 --height 460 \
  "$HOME/Library/Containers/rs.ruffle.ruffle/Data/Documents/conflashpin.swf" &

# 3. Capture 425 seconds of the Ruffle window through ScreenCaptureKit.
./sck_record visual_raw.mp4 425 --app ruffle

# 4. Crop Ruffle's title bar + menu bar away (keeping the 308x230 native stage at 2x = 616x460), skip the first 2 seconds (Ruffle splash), mux the album track underneath, trim to track length.
ffmpeg -ss 2 -i visual_raw.mp4 \
  -i "/path/to/Confield/1-01 VI Scose Poise.m4a" \
  -filter_complex "[0:v]crop=616:460:42:104,setpts=PTS-STARTPTS,fps=30[v]" \
  -map "[v]" -map 1:a \
  -t 416.98 \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 256k \
  -movflags +faststart \
  video/confield_promo.mp4
```

The audio file path is whatever local copy of the album you legally own. The crop offsets (`42`, `104`) are measured against Ruffle's macOS window chrome; if Ruffle's chrome dimensions change, re-measure with `ffmpeg -ss 5 -i visual_raw.mp4 -vframes 1 probe.png`.

## Provenance, in short

- Wayback snapshot used: `20010414031825` (2001-04-14 03:18:25 UTC).
- Ruffle web build pinned at: nightly `2026-04-30` (committed under `web/offline-bundle/ruffle/`).
- Original artifact hosted at `warprecords.com` (now redirects to `warp.net`); the `/confield/` path is no longer served.
- Album: Autechre, *Confield*, Warp WARP CD 102, released 2001-04-23.

## Acknowledgements

- The Internet Archive's Wayback Machine, without which this preservation would not be possible.
- The Ruffle project (https://ruffle.rs), the only reason a 2026 browser can play a Flash 4 file at all.

## Copyright

Original code in this repository: copyright (c) 2026 Jake Bromberg, licensed under the Anti-Capitalist Software License v1.4 (see LICENSE).

Preserved third-party artifacts retain their original copyright. See NOTICE for a per-file accounting and a takedown contact.
