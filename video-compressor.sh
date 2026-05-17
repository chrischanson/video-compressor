#!/usr/bin/env bash
#
# video-compressor.sh
#
# Compress video files while preserving the original structure:
#   - Video: AV1 via SVT-AV1.
#   - Audio: mono/stereo/unknown -> FLAC, surround -> Opus.
#   - Subtitles, attachments, chapters, and metadata are copied.
#   - DVD navigation/data packets are omitted because MKV cannot mux them.
#   - No crop, resize, deinterlace, scale, or other video filters are applied.
#
# Full encodes default to dry-run mode. Try-mode defaults to wet-run.
# If --wet-run is used and the system ffmpeg is missing the required encoders,
# a static BtbN ffmpeg build is downloaded automatically.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

CRF=24
PRESET=8
TRY_MODE=false
TRY_DURATION=300
TRY_START=0
WET_RUN=false
RUN_MODE_EXPLICIT=false
OVERWRITE=false
DEBUG=false
AUTO_BOOTSTRAP=true
FORCE_BOOTSTRAP=false
DVD_MERGE_VOBS=true
INPUT=""
OUTPUT=""
OUT_DIR=""
DVD_PROBESIZE=500M
DVD_ANALYZE_DURATION=300M

FFMPEG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/video-compressor/ffmpeg"
FFMPEG=""
FFPROBE=""

VIDEO_EXTS=(
  mkv mp4 m4v avi mov m2ts mts ts vob mpg mpeg wmv flv webm iso
)

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
fi

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [OPTIONS] <file-or-directory>

Options:
  --wet-run              Execute the encode. Full encodes default to dry-run.
  --dry-run              Print commands only. Useful to preview --try.
  --try                  Encode a short preview sample. Defaults to wet-run.
  --try-duration <sec>   Preview duration. Default: 300.
  --try-start <sec>      Preview start offset. Default: 0.
  --crf <0-63>           SVT-AV1 CRF quality. Default: 24.
  --preset <0-13>        SVT-AV1 speed preset. Default: 8.
  --output <path>        Single-file output path.
  --out-dir <path>       Output directory. Directory inputs preserve structure.
                         Also accepted as --output-root.
  --overwrite            Replace existing output files.
  --bootstrap            Download/install the static ffmpeg now. With an input,
                         install first and then continue.
  --no-auto-bootstrap    Do not auto-download ffmpeg during --wet-run.
  --no-dvd-merge         Treat DVD VOB chunks as separate files instead of
                         merging VTS_nn_1.VOB, VTS_nn_2.VOB, etc.
  --ffmpeg-dir <path>    Install/use static ffmpeg from this directory.
  --debug                Print ffmpeg's full output during encoding (verbose).
  --help, -h             Show this help.

Behavior:
  Video is encoded to AV1, audio is encoded per stream by channel count,
  subtitles/attachments are copied, DVD navigation data is omitted, and MKV
  output is used. Detected subtitle streams are reported before each encode.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

log() {
  printf '[INFO] %s\n' "$*"
}

need_value() {
  local opt="$1"
  local count="$2"
  (( count >= 2 )) || die "$opt requires a value"
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_numeric_options() {
  is_uint "$CRF" || die "--crf must be an integer"
  is_uint "$PRESET" || die "--preset must be an integer"
  is_uint "$TRY_DURATION" || die "--try-duration must be an integer"
  is_uint "$TRY_START" || die "--try-start must be an integer"

  (( CRF >= 0 && CRF <= 63 )) || die "--crf must be in range 0-63"
  (( PRESET >= 0 && PRESET <= 13 )) || die "--preset must be in range 0-13"
  (( TRY_DURATION > 0 )) || die "--try-duration must be greater than 0"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wet-run)
        WET_RUN=true
        RUN_MODE_EXPLICIT=true
        shift
        ;;
      --dry-run)
        WET_RUN=false
        RUN_MODE_EXPLICIT=true
        shift
        ;;
      --try)
        TRY_MODE=true
        shift
        ;;
      --try-duration)
        need_value "$1" "$#"
        TRY_DURATION="$2"
        shift 2
        ;;
      --try-start)
        need_value "$1" "$#"
        TRY_START="$2"
        shift 2
        ;;
      --crf)
        need_value "$1" "$#"
        CRF="$2"
        shift 2
        ;;
      --preset)
        need_value "$1" "$#"
        PRESET="$2"
        shift 2
        ;;
      --output)
        need_value "$1" "$#"
        OUTPUT="$2"
        shift 2
        ;;
      --out-dir|--output-root)
        need_value "$1" "$#"
        OUT_DIR="$2"
        shift 2
        ;;
      --overwrite)
        OVERWRITE=true
        shift
        ;;
      --bootstrap)
        FORCE_BOOTSTRAP=true
        shift
        ;;
      --no-auto-bootstrap)
        AUTO_BOOTSTRAP=false
        shift
        ;;
      --no-dvd-merge)
        DVD_MERGE_VOBS=false
        shift
        ;;
      --ffmpeg-dir)
        need_value "$1" "$#"
        FFMPEG_DIR="$2"
        shift 2
        ;;
      --debug)
        DEBUG=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          if [[ -n "$INPUT" ]]; then
            die "Only one input path is supported"
          fi
          INPUT="$1"
          shift
        done
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -n "$INPUT" ]]; then
          die "Only one input path is supported"
        fi
        INPUT="$1"
        shift
        ;;
    esac
  done
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

abs_path() {
  local path="$1"
  if command_exists realpath; then
    realpath -m -- "$path"
    return
  fi

  local dir base
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
  elif [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(pwd -P)" "$path"
  fi
}

encoder_exists_in_list() {
  local encoders="$1"
  local name="$2"
  awk -v name="$name" '$2 == name { found=1 } END { exit found ? 0 : 1 }' <<< "$encoders"
}

missing_toolchain_items() {
  local ff="$1"
  local fp="$2"
  local encoders=""

  if [[ ! -x "$ff" ]]; then
    printf '%s\n' "ffmpeg binary"
  else
    encoders="$("$ff" -hide_banner -encoders 2>/dev/null || true)"
    encoder_exists_in_list "$encoders" "libsvtav1" || printf '%s\n' "libsvtav1 encoder"
    encoder_exists_in_list "$encoders" "flac" || printf '%s\n' "flac encoder"
    encoder_exists_in_list "$encoders" "libopus" || printf '%s\n' "libopus encoder"
  fi

  if [[ ! -x "$fp" ]]; then
    printf '%s\n' "ffprobe binary"
  fi
}

toolchain_ok() {
  [[ -z "$(missing_toolchain_items "$1" "$2")" ]]
}

print_missing_toolchain() {
  local missing="$1"
  while IFS= read -r item; do
    [[ -n "$item" ]] && printf '  - %s\n' "$item" >&2
  done <<< "$missing"
}

download_file() {
  local url="$1"
  local dest="$2"

  if command_exists curl; then
    curl -fL --progress-bar -o "$dest" "$url"
  elif command_exists wget; then
    wget -O "$dest" "$url"
  else
    die "curl or wget is required to download ffmpeg"
  fi
}

bootstrap_ffmpeg() {
  local arch platform url tmpdir tarball ffmpeg_src ffprobe_src
  arch="$(uname -m)"

  case "$arch" in
    x86_64|amd64)
      platform="linux64"
      ;;
    aarch64|arm64)
      platform="linuxarm64"
      ;;
    *)
      die "Unsupported architecture for static ffmpeg: $arch"
      ;;
  esac

  command_exists tar || die "tar is required to install static ffmpeg"
  command_exists find || die "find is required to install static ffmpeg"
  command_exists install || die "install is required to install static ffmpeg"

  url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-${platform}-gpl.tar.xz"
  tmpdir="$(mktemp -d)"
  tarball="${tmpdir}/ffmpeg.tar.xz"
  trap 'rm -rf "$tmpdir"' RETURN

  log "Downloading static ffmpeg:"
  log "  $url"
  download_file "$url" "$tarball"

  log "Extracting static ffmpeg"
  tar -xf "$tarball" -C "$tmpdir"

  ffmpeg_src="$(find "$tmpdir" -type f -path '*/bin/ffmpeg' | head -n 1 || true)"
  ffprobe_src="$(find "$tmpdir" -type f -path '*/bin/ffprobe' | head -n 1 || true)"

  [[ -n "$ffmpeg_src" ]] || die "Downloaded archive did not contain ffmpeg"
  [[ -n "$ffprobe_src" ]] || die "Downloaded archive did not contain ffprobe"

  mkdir -p "$FFMPEG_DIR"
  install -m 0755 "$ffmpeg_src" "${FFMPEG_DIR}/ffmpeg"
  install -m 0755 "$ffprobe_src" "${FFMPEG_DIR}/ffprobe"

  FFMPEG="${FFMPEG_DIR}/ffmpeg"
  FFPROBE="${FFMPEG_DIR}/ffprobe"

  local missing
  missing="$(missing_toolchain_items "$FFMPEG" "$FFPROBE")"
  if [[ -n "$missing" ]]; then
    printf 'ERROR: Downloaded ffmpeg is missing required support:\n' >&2
    print_missing_toolchain "$missing"
    exit 1
  fi

  log "Installed ffmpeg to ${FFMPEG_DIR}"
  trap - RETURN
  rm -rf "$tmpdir"
}

resolve_ffmpeg() {
  local allow_download="$1"
  local cached_ff="${FFMPEG_DIR}/ffmpeg"
  local cached_fp="${FFMPEG_DIR}/ffprobe"
  local missing=""

  if toolchain_ok "$cached_ff" "$cached_fp"; then
    FFMPEG="$cached_ff"
    FFPROBE="$cached_fp"
    return
  fi

  if command_exists ffmpeg && command_exists ffprobe; then
    local system_ff system_fp
    system_ff="$(command -v ffmpeg)"
    system_fp="$(command -v ffprobe)"
    if toolchain_ok "$system_ff" "$system_fp"; then
      FFMPEG="$system_ff"
      FFPROBE="$system_fp"
      return
    fi

    missing="$(missing_toolchain_items "$system_ff" "$system_fp")"
    warn "System ffmpeg is not suitable:"
    print_missing_toolchain "$missing"
  else
    warn "System ffmpeg/ffprobe not found"
  fi

  if [[ "$AUTO_BOOTSTRAP" == "true" && "$allow_download" == "true" ]]; then
    bootstrap_ffmpeg
    return
  fi

  printf 'ERROR: No suitable ffmpeg toolchain found.\n' >&2
  printf 'Install one with:\n' >&2
  printf '  %s --bootstrap\n' "$SCRIPT_NAME" >&2
  if [[ "$WET_RUN" != "true" ]]; then
    printf 'Dry-run will not auto-download ffmpeg; --wet-run can auto-bootstrap when enabled.\n' >&2
  fi
  exit 1
}

is_video_path() {
  local lower="${1,,}"
  local ext
  for ext in "${VIDEO_EXTS[@]}"; do
    [[ "$lower" == *".${ext}" ]] && return 0
  done
  return 1
}

is_dvd_vob_part() {
  local base
  base="$(basename -- "$1")"
  [[ "$base" =~ ^VTS_[0-9][0-9]_[1-9][0-9]*\.[Vv][Oo][Bb]$ ]]
}

is_dvd_menu_vob() {
  local base
  base="$(basename -- "$1")"
  [[ "$base" =~ ^VTS_[0-9][0-9]_0\.[Vv][Oo][Bb]$ ]]
}

dvd_vob_title_id() {
  local base
  base="$(basename -- "$1")"
  if [[ "$base" =~ ^(VTS_[0-9][0-9])_[0-9]+\.[Vv][Oo][Bb]$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

escape_concat_path() {
  local path="$1"
  path="${path//\\/\\\\}"
  path="${path//|/\\|}"
  printf '%s\n' "$path"
}

concat_input_for_files() {
  local -n files_ref="$1"
  local joined="" file escaped

  for file in "${files_ref[@]}"; do
    escaped="$(escape_concat_path "$file")"
    if [[ -z "$joined" ]]; then
      joined="$escaped"
    else
      joined="${joined}|${escaped}"
    fi
  done

  printf 'concat:%s\n' "$joined"
}

collect_directory_inputs() {
  local root="$1"
  local exclude_root="$2"
  local -n out_ref="$3"
  local file file_abs

  while IFS= read -r -d '' file; do
    file_abs="$(abs_path "$file")"
    if [[ -n "$exclude_root" ]]; then
      [[ "$file_abs" == "$exclude_root" || "$file_abs" == "${exclude_root}/"* ]] && continue
    fi
    out_ref+=("$file_abs")
  done < <(
    find "$root" -type f \( \
      -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o \
      -iname '*.avi' -o -iname '*.mov' -o -iname '*.m2ts' -o \
      -iname '*.mts' -o -iname '*.ts' -o -iname '*.vob' -o \
      -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.wmv' -o \
      -iname '*.flv' -o -iname '*.webm' -o -iname '*.iso' \
    \) ! -iname '*-compressed.mkv' ! -iname '*-compressed-try.mkv' -print0 | sort -z
  )
}

needs_deep_probe() {
  local input="$1"
  local probe_input="$2"
  local probe_lower="${probe_input,,}"

  [[ "$input" == concat:* || "$probe_lower" == *.vob || "$probe_lower" == *.ts || "$probe_lower" == *.mts ]]
}

add_probe_options() {
  local input="$1"
  local probe_input="$2"
  local -n args_ref="$3"

  if needs_deep_probe "$input" "$probe_input"; then
    args_ref+=(-probesize "$DVD_PROBESIZE" -analyzeduration "$DVD_ANALYZE_DURATION")
  fi
}

# ─── Stream probing and media-summary table ─────────────────────────────────

# Deduplicate ffprobe compact-output stream lines by stream index.
# Multi-program transport streams (e.g. DVB broadcast .ts files) cause ffprobe
# to emit the same elementary stream once per program/service that references
# it.  We keep the LAST occurrence of each index so that the richer per-program
# metadata (e.g. language tags present in the second PMT entry) wins over the
# first, tag-free listing.  Without this, -map 0:a? would encode the same
# audio track once per program, producing duplicate output tracks.
dedup_streams_by_index() {
  awk -F'|' '
  {
    idx = ""
    for (i = 1; i <= NF; i++) {
      eq = index($i, "=")
      if (eq > 0 && substr($i, 1, eq - 1) == "index") {
        idx = substr($i, eq + 1)
        break
      }
    }
    if (idx == "") { print; next }
    if (!(idx in seen)) order[n++] = idx
    seen[idx] = $0
  }
  END {
    for (i = 0; i < n; i++) print seen[order[i]]
  }'
}

# Probe all streams of a file; outputs ffprobe compact key=value lines.
# Includes color metadata for video streams so a single probe serves all needs.
probe_all_streams() {
  local probe_input="$1"
  local input="$2"
  local -a cmd=("$FFPROBE" -v error)
  add_probe_options "$input" "$probe_input" cmd
  cmd+=(
    -show_entries \
      "stream=index,codec_type,codec_name,width,height,r_frame_rate,channels,channel_layout,sample_rate,bit_rate,color_primaries,color_transfer,color_space:stream_tags=language,title"
    -of compact=p=0:nk=0
    "$probe_input"
  )
  "${cmd[@]}" 2>/dev/null | dedup_streams_by_index || true
}

# Extract the value of a named field from one compact ffprobe line.
_stream_field() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | awk -F'|' -v k="$key" '{
    for (i = 1; i <= NF; i++) {
      eq = index($i, "=")
      if (eq > 0 && substr($i, 1, eq - 1) == k) {
        v = substr($i, eq + 1)
        if (v != "N/A" && v != "") print v
        exit
      }
    }
  }'
}

# Convert a "num/den" frame-rate fraction to a 3-decimal string.
_fps_decimal() {
  local num="${1%%/*}" den="${1##*/}"
  if [[ -n "$den" && "$den" != "0" ]]; then
    awk -v n="$num" -v d="$den" 'BEGIN { printf "%.3f", n / d }'
  else
    printf '%s' "$1"
  fi
}

_human_bitrate() {
  local bits="$1"
  [[ "$bits" =~ ^[0-9]+$ && "$bits" -gt 0 ]] || return 0

  awk -v b="$bits" 'BEGIN {
    if (b >= 1000000) printf "%.1f Mb/s", b / 1000000;
    else printf "%.0f kb/s", b / 1000;
  }'
}

_stream_suffix() {
  local lang="$1"
  local title="$2"
  local out=""

  [[ -n "$lang" ]] && out+=" [${lang}]"
  [[ -n "$title" ]] && out+="${out:+ }${title}"
  printf '%s' "$out"
}

_friendly_codec() {
  case "$1" in
    dvd_subtitle)                    printf 'dvd' ;;
    hdmv_pgs_subtitle)               printf 'pgs' ;;
    dvb_subtitle)                   printf 'dvb' ;;
    dvb_teletext)                   printf 'teletext' ;;
    subrip)                         printf 'srt' ;;
    ass|ssa)                        printf 'ass' ;;
    *)                              printf '%s' "${1:-?}" ;;
  esac
}

# Given a VOB path, return the sibling IFO path (VTS_nn_0.IFO) if it exists.
_ifo_for_vob() {
  local vob="$1"
  local base dir ifo
  base="$(basename -- "$vob")"
  dir="$(dirname  -- "$vob")"
  # Match VTS_nn_k.VOB -> VTS_nn_0.IFO
  if [[ "$base" =~ ^(VTS_[0-9]+)_[0-9]+\.[Vv][Oo][Bb]$ ]]; then
    ifo="${dir}/${BASH_REMATCH[1]}_0.IFO"
    # Also try lowercase extension
    [[ -f "$ifo" ]] || ifo="${dir}/${BASH_REMATCH[1]}_0.ifo"
    [[ -f "$ifo" ]] && printf '%s\n' "$ifo"
  fi
}

# Probe subtitle streams from the IFO and return "index lang title" lines.
_ifo_subtitle_langs() {
  local ifo="$1"
  "$FFPROBE" -v error \
    -select_streams s \
    -show_entries "stream=index:stream_tags=language,title" \
    -of compact=p=0:nk=0 \
    "$ifo" 2>/dev/null || true
}

# Print a stream-by-stream encoding plan.
# Accepts pre-probed stream data so the probe is done only once per file.
print_media_summary() {
  local streams="$1"
  local probe_input="$2"

  local -a ifo_sub_langs=()
  local -a ifo_sub_titles=()
  local ifo="" probe_lower="${probe_input,,}"
  if [[ "$probe_lower" == *.vob ]]; then
    ifo="$(_ifo_for_vob "$probe_input" || true)"
  fi
  if [[ -n "$ifo" ]]; then
    local ifo_line
    while IFS= read -r ifo_line; do
      [[ -n "$ifo_line" ]] || continue
      ifo_sub_langs+=("$(_stream_field "$ifo_line" "tag:language")")
      ifo_sub_titles+=("$(_stream_field "$ifo_line" "tag:title")")
    done < <(_ifo_subtitle_langs "$ifo")
  fi

  local total=0 video_idx=0 audio_idx=0 sub_idx=0
  local line ctype cname index width height fps ch layout sr bitrate lang title info out filter suffix

  printf '  %b%s%b\n' "$C_CYAN" "streams" "$C_RESET"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ctype="$(_stream_field "$line" codec_type)"
    cname="$(_stream_field "$line" codec_name)"
    index="$(_stream_field "$line" index)"
    lang="$(_stream_field  "$line" "tag:language")"
    title="$(_stream_field "$line" "tag:title")"
    ((total += 1))

    case "$ctype" in
      video)
        width="$(_stream_field "$line" width)"
        height="$(_stream_field "$line" height)"
        fps="$(_stream_field "$line" r_frame_rate)"
        bitrate="$(_human_bitrate "$(_stream_field "$line" bit_rate)")"
        [[ -n "$fps" ]] && fps="$(_fps_decimal "$fps")"

        info="$(_friendly_codec "$cname")"
        [[ -n "$width" && -n "$height" ]] && info+=" ${width}×${height}"
        [[ -n "$fps" ]] && info+=" ${fps}fps"
        [[ -n "$bitrate" ]] && info+=" ${bitrate}"
        suffix="$(_stream_suffix "$lang" "$title")"
        [[ -n "$suffix" ]] && info+="$suffix"

        if (( video_idx == 0 )); then
          out="AV1 libsvtav1 crf=${CRF} preset=${PRESET}"
        else
          out="skipped"
        fi
        printf '    %bvideo     #%s%b %s -> %s\n' "$C_DIM" "${index:-?}" "$C_RESET" "$info" "$out"
        ((video_idx += 1))
        ;;
      audio)
        ch="$(_stream_field "$line" channels)"
        layout="$(_stream_field "$line" channel_layout)"
        sr="$(_stream_field "$line" sample_rate)"
        bitrate="$(_human_bitrate "$(_stream_field "$line" bit_rate)")"

        info="$(_friendly_codec "$cname")"
        if [[ -n "$layout" ]]; then
          info+=" ${layout}"
        elif [[ -n "$ch" ]]; then
          info+=" ${ch}ch"
        fi
        [[ -n "$sr" ]] && info+=" ${sr}Hz"
        [[ -n "$bitrate" ]] && info+=" ${bitrate}"
        suffix="$(_stream_suffix "$lang" "$title")"
        [[ -n "$suffix" ]] && info+="$suffix"

        if [[ "$ch" =~ ^[0-9]+$ && "$ch" -gt 2 ]]; then
          out="Opus $(opus_bitrate_for_channels "$ch")"
          filter="$(opus_filter_for_layout "$ch" "$layout")"
          [[ -n "$filter" ]] && out+=" (layout normalized to 5.1)"
        else
          out="FLAC lossless"
        fi
        printf '    %baudio     #%s%b %s -> %s\n' "$C_DIM" "${index:-?}" "$C_RESET" "$info" "$out"
        ((audio_idx += 1))
        ;;
      subtitle)
        if (( ${#ifo_sub_langs[@]} > sub_idx )); then
          [[ -n "${ifo_sub_langs[$sub_idx]}" ]] && lang="${ifo_sub_langs[$sub_idx]}"
          [[ -n "${ifo_sub_titles[$sub_idx]}" ]] && title="${ifo_sub_titles[$sub_idx]}"
        fi

        info="$(_friendly_codec "$cname")"
        suffix="$(_stream_suffix "$lang" "$title")"
        if [[ -n "$suffix" ]]; then
          info+="$suffix"
        else
          info+=" [?]"
        fi
        printf '    %bsubtitle  #%s%b %s -> copy\n' "$C_DIM" "${index:-?}" "$C_RESET" "$info"
        ((sub_idx += 1))
        ;;
    esac
  done <<< "$streams"

  if (( total == 0 )); then
    printf '    %b%s%b\n' "$C_YELLOW" "(no streams detected by ffprobe)" "$C_RESET"
  fi
}

is_known_color_value() {
  [[ -n "$1" && "$1" != "unknown" && "$1" != "unspecified" && "$1" != "reserved" && "$1" != "N/A" ]]
}

normalize_color_transfer() {
  case "$1" in
    bt470bg)
      printf '%s\n' "gamma28"
      ;;
    bt470m)
      printf '%s\n' "gamma22"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

# Add color-metadata ffmpeg args from pre-probed stream data.
_add_color_args_from_data() {
  local streams="$1"
  local -n cmd_ref="$2"
  local line ctype prim trc space

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ctype="$(_stream_field "$line" codec_type)"
    [[ "$ctype" == "video" ]] || continue
    prim="$(_stream_field "$line" color_primaries)"
    trc="$(_stream_field "$line" color_transfer)"
    space="$(_stream_field "$line" color_space)"
    trc="$(normalize_color_transfer "$trc")"
    is_known_color_value "$prim" && cmd_ref+=(-color_primaries "$prim")
    is_known_color_value "$trc" && cmd_ref+=(-color_trc "$trc")
    is_known_color_value "$space" && cmd_ref+=(-colorspace "$space")
    break
  done <<< "$streams"
}

opus_bitrate_for_channels() {
  local channels="$1"
  if (( channels <= 4 )); then
    printf '256k\n'
  elif (( channels <= 6 )); then
    printf '384k\n'
  else
    printf '512k\n'
  fi
}

opus_filter_for_layout() {
  local channels="$1"
  local layout="$2"

  if [[ "$channels" == "6" && "$layout" == "5.1(side)" ]]; then
    printf '%s\n' "pan=5.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=SL|BR=SR"
  fi
}

# Add per-stream audio encoder args from pre-probed stream data.
_add_audio_args_from_data() {
  local streams="$1"
  local -n cmd_ref="$2"
  local idx=0 channels layout bitrate filter line ctype

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ctype="$(_stream_field "$line" codec_type)"
    [[ "$ctype" == "audio" ]] || continue
    channels="$(_stream_field "$line" channels)"
    layout="$(_stream_field "$line" channel_layout)"

    if [[ "$channels" =~ ^[0-9]+$ && "$channels" -gt 2 ]]; then
      bitrate="$(opus_bitrate_for_channels "$channels")"
      filter="$(opus_filter_for_layout "$channels" "$layout")"
      [[ -n "$filter" ]] && cmd_ref+=(-filter:a:"$idx" "$filter")
      cmd_ref+=(-c:a:"$idx" libopus -b:a:"$idx" "$bitrate" -vbr:a:"$idx" on -mapping_family:a:"$idx" 1)
    else
      cmd_ref+=(-c:a:"$idx" flac -compression_level:a:"$idx" 8)
    fi

    ((idx += 1))
  done <<< "$streams"
}

build_command() {
  local input="$1"
  local probe_input="$2"
  local output="$3"
  local cmd_name="$4"
  local streams="$5"
  local -n cmd_ref="$cmd_name"

  cmd_ref=("$FFMPEG" -hide_banner)
  # Suppress ffmpeg's verbose stream/format info and per-frame stats by default.
  # --debug restores full output for troubleshooting.
  if [[ "$DEBUG" != "true" ]]; then
    cmd_ref+=(-loglevel error -nostats)
  fi
  if [[ "$OVERWRITE" == "true" ]]; then
    cmd_ref+=(-y)
  else
    cmd_ref+=(-n)
  fi

  if [[ "$TRY_MODE" == "true" ]]; then
    (( TRY_START > 0 )) && cmd_ref+=(-ss "$TRY_START")
    cmd_ref+=(-t "$TRY_DURATION")
  fi

  add_probe_options "$input" "$probe_input" "$cmd_name"

  cmd_ref+=(
    -i "$input"
    -map "0:v:0"
    -map "0:a?"
    -map "0:s?"
    -map "0:t?"
    -map_metadata 0
    -map_chapters 0
    -c:v libsvtav1
    -crf "$CRF"
    -preset "$PRESET"
    -svtav1-params "tune=0:film-grain=0:log=0"
    -c:s copy
    -c:t copy
    -max_muxing_queue_size 4096
  )

  _add_color_args_from_data "$streams" "$cmd_name"
  _add_audio_args_from_data "$streams" "$cmd_name"

  cmd_ref+=("$output")
}

print_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

common_dir() {
  local left="$1"
  local right="$2"
  local common=""
  local old_ifs="$IFS"
  local -a left_parts=()
  local -a right_parts=()
  local i max

  left="$(abs_path "$left")"
  right="$(abs_path "$right")"
  IFS='/' read -r -a left_parts <<< "${left#/}"
  IFS='/' read -r -a right_parts <<< "${right#/}"
  IFS="$old_ifs"

  max="${#left_parts[@]}"
  (( ${#right_parts[@]} < max )) && max="${#right_parts[@]}"

  for ((i = 0; i < max; i++)); do
    [[ "${left_parts[$i]}" == "${right_parts[$i]}" ]] || break
    common+="/${left_parts[$i]}"
  done

  printf '%s\n' "${common:-/}"
}

relative_to_dir() {
  local path="$1"
  local root="$2"

  path="$(abs_path "$path")"
  root="$(abs_path "$root")"

  if [[ "$root" == "/" ]]; then
    printf '%s\n' "${path#/}"
  elif [[ "$path" == "$root" ]]; then
    printf '.\n'
  elif [[ "$path" == "$root/"* ]]; then
    printf '%s\n' "${path#"$root/"}"
  else
    printf '%s\n' "$path"
  fi
}

print_path_summary() {
  local label="$1"
  local probe_input="$2"
  local output="$3"
  local input_name="$label"
  local output_name output_dir root input_rel output_rel

  if [[ "$label" == /* ]]; then
    input_name="$(basename -- "$label")"
  fi

  output_name="$(basename -- "$output")"
  output_dir="$(dirname -- "$output")"

  if [[ "$probe_input" == /* ]]; then
    root="$(common_dir "$(dirname -- "$probe_input")" "$output_dir")"
    input_rel="$(relative_to_dir "$probe_input" "$root")"
    output_rel="$(relative_to_dir "$output" "$root")"
    printf '%b%s%b  %s\n' "$C_DIM" "root" "$C_RESET" "$root"
    if [[ "$label" == /* ]]; then
      printf '%b%s%b %s\n' "$C_BOLD" "input" "$C_RESET" "$input_rel"
    else
      printf '%b%s%b %s\n' "$C_BOLD" "input" "$C_RESET" "$input_name"
      printf '  %bfirst chunk%b %s\n' "$C_DIM" "$C_RESET" "$input_rel"
    fi
    printf '%b%s%b %s\n' "$C_BOLD" "output" "$C_RESET" "$output_rel"
  else
    printf '%b%s%b %s\n' "$C_BOLD" "input" "$C_RESET" "$input_name"
    printf '%b%s%b %s\n' "$C_BOLD" "output" "$C_RESET" "$output_name"
    printf '  %bto%b   %s\n' "$C_DIM" "$C_RESET" "$output_dir"
  fi
}

output_for_file() {
  local input="$1"
  local input_root="$2"
  local output_root="$3"
  local suffix="-compressed"
  local stem rel out_dir

  [[ "$TRY_MODE" == "true" ]] && suffix="-compressed-try"

  if [[ -n "$OUTPUT" ]]; then
    printf '%s\n' "$(abs_path "$OUTPUT")"
    return
  fi

  stem="$(basename "${input%.*}")"

  if [[ -z "$output_root" ]]; then
    printf '%s/%s%s.mkv\n' "$(dirname -- "$input")" "$stem" "$suffix"
    return
  fi

  if [[ -n "$input_root" ]]; then
    rel="${input#"${input_root}/"}"
    out_dir="${output_root}/$(dirname -- "$rel")"
    [[ "$(dirname -- "$rel")" == "." ]] && out_dir="$output_root"
  else
    out_dir="$output_root"
  fi

  printf '%s/%s%s.mkv\n' "$out_dir" "$stem" "$suffix"
}

output_for_dvd_group() {
  local first_file="$1"
  local input_root="$2"
  local output_root="$3"
  local title_id="$4"
  local suffix="-compressed"
  local rel out_dir

  [[ "$TRY_MODE" == "true" ]] && suffix="-compressed-try"

  if [[ -z "$output_root" ]]; then
    out_dir="$(dirname -- "$first_file")"
  else
    rel="${first_file#"${input_root}/"}"
    out_dir="${output_root}/$(dirname -- "$rel")"
    [[ "$(dirname -- "$rel")" == "." ]] && out_dir="$output_root"
  fi

  printf '%s/%s%s.mkv\n' "$out_dir" "$title_id" "$suffix"
}

process_one() {
  local input="$1"
  local probe_input="$2"
  local output="$3"
  local label="$4"
  local -a cmd
  local input_real output_real

  if [[ "$input" != concat:* ]]; then
    input_real="$(abs_path "$input")"
    output_real="$(abs_path "$output")"

    if [[ "$input_real" == "$output_real" ]]; then
      warn "Skipping because output would overwrite input: $input"
      return 0
    fi
  fi

  if [[ -e "$output" && "$OVERWRITE" != "true" ]]; then
    warn "Skipping existing output: $output"
    return 0
  fi

  # Single probe for the entire file — used for both display and command building.
  local streams
  streams="$(probe_all_streams "$probe_input" "$input")"

  local mode_str="FULL"
  [[ "$TRY_MODE" == "true" ]] && mode_str="TRY (${TRY_DURATION}s from ${TRY_START}s)"

  printf '\n'
  printf '%b%s%b %s\n' "$C_GREEN" "==>" "$C_RESET" "$mode_str"
  print_path_summary "$label" "$probe_input" "$output"
  print_media_summary "$streams" "$probe_input"

  build_command "$input" "$probe_input" "$output" cmd "$streams"

  if [[ "$WET_RUN" != "true" ]]; then
    printf '%b%s%b\n' "$C_YELLOW" "dry-run command:" "$C_RESET"
    print_cmd "${cmd[@]}"
    return 0
  fi

  mkdir -p "$(dirname -- "$output")"
  printf '%b%s%b\n' "$C_GREEN" "running:" "$C_RESET"
  print_cmd "${cmd[@]}"
  "${cmd[@]}"
}

main() {
  parse_args "$@"
  if [[ "$TRY_MODE" == "true" && "$RUN_MODE_EXPLICIT" != "true" ]]; then
    WET_RUN=true
  fi
  validate_numeric_options

  [[ -n "$OUTPUT" && -n "$OUT_DIR" ]] && die "--output and --out-dir cannot be used together"

  if [[ "$FORCE_BOOTSTRAP" == "true" ]]; then
    bootstrap_ffmpeg
    if [[ -z "$INPUT" ]]; then
      exit 0
    fi
  fi

  [[ -n "$INPUT" ]] || die "No input specified. Use --help for usage."
  [[ -e "$INPUT" ]] || die "Input path not found: $INPUT"

  if [[ -d "$INPUT" && -n "$OUTPUT" ]]; then
    die "--output is only valid for a single input file; use --out-dir for directories"
  fi

  resolve_ffmpeg "$WET_RUN"

  local input_abs output_root="" exclude_root="" root_for_rel=""
  local -a source_files=()
  local -a item_inputs=()
  local -a item_probes=()
  local -a item_outputs=()
  local -a item_labels=()
  local dvd_group_count=0 skipped_dvd_menus=0

  input_abs="$(abs_path "$INPUT")"

  if [[ -f "$input_abs" ]]; then
    if ! is_video_path "$input_abs"; then
      warn "Input extension is not in the usual video list; ffmpeg will decide whether it is valid"
    fi
    if [[ -n "$OUT_DIR" ]]; then
      [[ "$WET_RUN" == "true" ]] && mkdir -p "$OUT_DIR"
      output_root="$(abs_path "$OUT_DIR")"
    fi
    item_inputs+=("$input_abs")
    item_probes+=("$input_abs")
    item_outputs+=("$(output_for_file "$input_abs" "" "$output_root")")
    item_labels+=("$input_abs")
  elif [[ -d "$input_abs" ]]; then
    if [[ -n "$OUT_DIR" ]]; then
      [[ "$WET_RUN" == "true" ]] && mkdir -p "$OUT_DIR"
      output_root="$(abs_path "$OUT_DIR")"
    else
      output_root="${input_abs}/compressed"
    fi
    exclude_root="$(abs_path "$output_root")"
    root_for_rel="$input_abs"
    collect_directory_inputs "$input_abs" "$exclude_root" source_files

    if [[ "$DVD_MERGE_VOBS" == "true" ]]; then
      declare -A dvd_groups=()
      declare -A dvd_titles=()
      local -a normal_files=()
      local file title_id dvd_dir dvd_key

      for file in "${source_files[@]+"${source_files[@]}"}"; do
        if is_dvd_vob_part "$file"; then
          title_id="$(dvd_vob_title_id "$file")"
          dvd_dir="$(dirname -- "$file")"
          dvd_key="${dvd_dir}"$'\t'"${title_id}"
          dvd_groups["$dvd_key"]+="${file}"$'\n'
          dvd_titles["$dvd_key"]="$title_id"
        elif is_dvd_menu_vob "$file"; then
          ((skipped_dvd_menus += 1))
        else
          normal_files+=("$file")
        fi
      done

      if (( ${#normal_files[@]} > 0 )); then
        source_files=("${normal_files[@]}")
      else
        source_files=()
      fi

      if (( ${#dvd_groups[@]} > 0 )); then
        while IFS= read -r dvd_key; do
          local group_text group_file concat_input output first_file label
          local -a group_files=()

          group_text="${dvd_groups[$dvd_key]}"
          while IFS= read -r group_file; do
            [[ -n "$group_file" ]] && group_files+=("$group_file")
          done <<< "$group_text"

          (( ${#group_files[@]} > 0 )) || continue
          mapfile -t group_files < <(printf '%s\n' "${group_files[@]}" | sort -V)

          title_id="${dvd_titles[$dvd_key]}"
          first_file="${group_files[0]}"
          concat_input="$(concat_input_for_files group_files)"
          output="$(output_for_dvd_group "$first_file" "$root_for_rel" "$output_root" "$title_id")"
          label="DVD ${title_id} ($(basename -- "$(dirname -- "$first_file")"), ${#group_files[@]} VOB chunks)"

          item_inputs+=("$concat_input")
          item_probes+=("$first_file")
          item_outputs+=("$output")
          item_labels+=("$label")
          ((dvd_group_count += 1))
        done < <(printf '%s\n' "${!dvd_groups[@]}" | sort)
      fi
    fi

    local file output
    for file in "${source_files[@]+"${source_files[@]}"}"; do
      output="$(output_for_file "$file" "$root_for_rel" "$output_root")"
      item_inputs+=("$file")
      item_probes+=("$file")
      item_outputs+=("$output")
      item_labels+=("$file")
    done
  else
    die "Input is neither a regular file nor a directory: $INPUT"
  fi

  (( ${#item_inputs[@]} > 0 )) || die "No video files found"

  local mode_label="wet-run"
  [[ "$WET_RUN" != "true" ]] && mode_label="dry-run"

  log "Ready: ${#item_inputs[@]} file(s), ${mode_label}, ffmpeg=$(basename -- "$FFMPEG")"
  if (( dvd_group_count > 0 )); then
    log "DVD VOB groups: ${dvd_group_count} merged title set(s)"
  fi
  if (( skipped_dvd_menus > 0 )); then
    log "DVD menu VOBs skipped: ${skipped_dvd_menus}"
  fi

  local i
  for i in "${!item_inputs[@]}"; do
    process_one "${item_inputs[$i]}" "${item_probes[$i]}" "${item_outputs[$i]}" "${item_labels[$i]}"
  done

  printf '\n'
  log "Done"
}

main "$@"
