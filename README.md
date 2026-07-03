# video-compressor

> **Archive-quality AV1 compression for your video library — one script, no hand-tuned ffmpeg flags.**

A single Bash script that re-encodes video files to **AV1 (SVT-AV1)** with
smart audio handling, preserving subtitles, chapters, attachments, and the
original directory structure. Defaults to **dry-run** so you can preview every
encode before committing to it.

![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Bash](https://img.shields.io/badge/bash-5.x-blue)
![Codec](https://img.shields.io/badge/video-AV1%20(SVT--AV1)-purple)

---

## Why

Re-encoding a library by hand means juggling per-file ffmpeg commands, codec
selection, audio channel logic, and subtitle streams. `video-compressor.sh`
automates all of it with sensible defaults:

- **AV1 video** via SVT-AV1 — modern, efficient, archival.
- **Audio by channel count** — mono/stereo/unknown → FLAC; surround → Opus.
- **Subtitles, attachments, chapters, metadata** are copied unchanged.
- **Structure preserved** — point it at a directory and it walks the tree.
- **Self-bootstrapping** — if your system `ffmpeg` lacks the encoders, it
  downloads a static BtbN build automatically (no manual setup).
- **DVD-aware** — merges `VTS_nn_*.VOB` chunks into single titles.

---

## Features

- 🎬 **AV1 / SVT-AV1** encoding with tunable CRF and preset.
- 🔊 **Automatic audio codec selection** based on channel layout.
- 🧪 **`--try` mode** — encode a short preview sample (default 300s) before
  committing to a full encode.
- 🏜️ **Dry-run by default** — prints the exact ffmpeg commands; pass
  `--wet-run` to execute.
- 📁 **Directory recursion** with output structure mirroring the input.
- 🔄 **DVD VOB merging** — combines `VTS_nn_1.VOB`, `VTS_nn_2.VOB`, …
- 📦 **Auto-bootstrap ffmpeg** — fetches a static build on demand.
- 🧹 No crop, no resize, no deinterlace, no scaling — lossless geometry.

---

## Quick Start

```bash
# Preview what would be encoded (dry-run, no files written)
./video-compressor.sh /path/to/movies

# Encode a 5-minute preview sample (wet-run)
./video-compressor.sh --try /path/to/movie.mkv

# Full encode, writing into an output directory
./video-compressor.sh --wet-run --out-dir ./compressed /path/to/movies
```

### Requirements

- Bash 5+, `ffmpeg`/`ffprobe` with SVT-AV1 and the audio encoders.
- If your `ffmpeg` is missing the encoders, the script auto-downloads a static
  build (pass `--bootstrap` to force it, or `--no-auto-bootstrap` to disable).

---

## Options

| Option | Default | Description |
|---|---|---|
| `--wet-run` | off | Execute the encode (full encodes default to dry-run) |
| `--dry-run` | on | Print commands only |
| `--try` | off | Encode a short preview sample (defaults to wet-run) |
| `--try-duration <sec>` | `300` | Preview duration |
| `--try-start <sec>` | `0` | Preview start offset |
| `--crf <0-63>` | `24` | SVT-AV1 CRF quality |
| `--preset <0-13>` | `8` | SVT-AV1 speed preset |
| `--threads <N>` | nproc/4 | Encoder thread count |
| `--output <path>` | — | Single-file output path |
| `--out-dir <path>` | — | Output directory (structure preserved) |
| `--overwrite` | off | Replace existing output files |
| `--bootstrap` | off | Install the static ffmpeg now |
| `--no-auto-bootstrap` | off | Don't auto-download ffmpeg during `--wet-run` |
| `--no-dvd-merge` | off | Treat DVD VOB chunks as separate files |
| `--ffmpeg-dir <path>` | XDG data dir | Install/use static ffmpeg from this dir |
| `--debug` | off | Print ffmpeg's full output during encoding |

Run `./video-compressor.sh --help` for the full reference.

---

## Testing

```bash
# Bazel build + tests
bazel test //public_projects/video-compressor/...

# Or run the test harness directly
bash public_projects/video-compressor/tests/test-video-compressor.sh
```

The test suite uses fake `ffmpeg`/`ffprobe` binaries (in `tests/fakes/`) so it
runs without a real encoder installed.

---

## Project Structure

```
video-compressor.sh   The compressor (single self-contained script)
BUILD.bazel           Bazel target exporting the script
tests/                Test harness + fake ffmpeg/ffprobe fixtures
```

---

## License

MIT — see [LICENSE](LICENSE).
