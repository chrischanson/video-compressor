#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../video-compressor.sh"
FAKES_DIR="${TEST_DIR}/fakes"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "${message}: missing '${needle}'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "${message}: unexpectedly found '${needle}'"
}

run_script() {
  XDG_DATA_HOME="${TMPDIR}/xdg" "$SCRIPT" --ffmpeg-dir "$FAKES_DIR" "$@"
}

setup_media_tree() {
  mkdir -p "${TMPDIR}/dvd/VIDEO_TS" "${TMPDIR}/bluray"
  touch \
    "${TMPDIR}/dvd/VIDEO_TS/VTS_02_0.VOB" \
    "${TMPDIR}/dvd/VIDEO_TS/VTS_02_0.IFO" \
    "${TMPDIR}/dvd/VIDEO_TS/VTS_02_1.VOB" \
    "${TMPDIR}/dvd/VIDEO_TS/VTS_02_2.VOB" \
    "${TMPDIR}/bluray/1 Part I.ts"
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
setup_media_tree

bash -n "$SCRIPT"
pass "video-compressor.sh parses as Bash"

dvd_try_dry="$(run_script --try --dry-run "${TMPDIR}/dvd")"
assert_contains "$dvd_try_dry" "Ready: 1 file(s), dry-run" "DVD dry-run summary"
assert_contains "$dvd_try_dry" "DVD VOB groups: 1 merged title set(s)" "DVD VOB chunks are grouped"
assert_contains "$dvd_try_dry" "DVD menu VOBs skipped: 1" "DVD menu VOB is skipped"
assert_contains "$dvd_try_dry" "concat:${TMPDIR}/dvd/VIDEO_TS/VTS_02_1.VOB\\|${TMPDIR}/dvd/VIDEO_TS/VTS_02_2.VOB" "DVD concat input is built"
assert_not_contains "$dvd_try_dry" "VTS_02_0.VOB\\|" "DVD concat excludes menu VOB"
assert_contains "$dvd_try_dry" "-map 0:v:0" "only primary video is mapped"
assert_not_contains "$dvd_try_dry" "-map 0 " "legacy map-all is not used"
assert_not_contains "$dvd_try_dry" "-c:d copy" "DVD nav/data streams are not copied"
assert_contains "$dvd_try_dry" "root  ${TMPDIR}/dvd" "common root is shown once"
assert_contains "$dvd_try_dry" "first chunk VIDEO_TS/VTS_02_1.VOB" "DVD input chunk is relative to root"
assert_contains "$dvd_try_dry" "output compressed/VIDEO_TS/VTS_02-compressed-try.mkv" "DVD output is relative to root"
assert_contains "$dvd_try_dry" "video     #0 mpeg2video 720×576 25.000fps 7.5 Mb/s -> AV1 libsvtav1 crf=24 preset=8" "DVD video plan is detailed"
assert_contains "$dvd_try_dry" "audio     #1 ac3 stereo 48000Hz 192 kb/s [eng] -> FLAC lossless" "DVD stereo audio plan is detailed"
assert_contains "$dvd_try_dry" "audio     #2 ac3 5.1 48000Hz 448 kb/s -> Opus 384k" "DVD surround audio plan is detailed"
assert_contains "$dvd_try_dry" "subtitle  #3 dvd [eng] -> copy" "DVD subtitle plan is detailed"
assert_not_contains "$dvd_try_dry" "┌" "box drawing output is removed"
assert_not_contains "$dvd_try_dry" "│" "box drawing output is removed"
pass "DVD grouping, stream mapping, detailed plan, and concise output are stable"

try_wet="$(run_script --try "${TMPDIR}/dvd")"
assert_contains "$try_wet" "Ready: 1 file(s), wet-run" "--try defaults to wet-run"
assert_contains "$try_wet" "running:" "--try runs by default"
assert_contains "$try_wet" "FAKE_FFMPEG_RUN" "fake ffmpeg was executed in try mode"
pass "try mode defaults to wet-run"

full_dry="$(run_script "${TMPDIR}/bluray/1 Part I.ts")"
assert_contains "$full_dry" "Ready: 1 file(s), dry-run" "full encode defaults to dry-run"
assert_contains "$full_dry" "dry-run command:" "full encode prints dry-run command"
assert_not_contains "$full_dry" "FAKE_FFMPEG_RUN" "full dry-run does not execute ffmpeg"
pass "full mode defaults to dry-run"

ts_try_dry="$(run_script --try --dry-run "${TMPDIR}/bluray/1 Part I.ts")"
assert_contains "$ts_try_dry" "input 1 Part I.ts" "TS input path is relative to common root"
assert_contains "$ts_try_dry" "video     #0 mpeg2video 1920×1080 25.000fps 16.0 Mb/s -> AV1 libsvtav1 crf=24 preset=8" "TS primary video plan is detailed"
assert_contains "$ts_try_dry" "video     #1 mpeg2video 1920×1080 25.000fps 16.0 Mb/s -> skipped" "TS secondary video stream is explicitly skipped"
assert_contains "$ts_try_dry" "audio     #2 ac3 5.1(side) 48000Hz 448 kb/s [eng] -> Opus 384k (layout normalized to 5.1)" "TS summary shows 5.1(side) layout and output"
assert_contains "$ts_try_dry" "-filter:a:0 pan=5.1\\|FL=FL\\|FR=FR\\|FC=FC\\|LFE=LFE\\|BL=SL\\|BR=SR" "5.1(side) audio is normalized for Opus"
assert_contains "$ts_try_dry" "-mapping_family:a:0 1" "Opus surround mapping family is set"
assert_contains "$ts_try_dry" "subtitle  #4 dvb [eng] English SDH -> copy" "TS first subtitle is detailed"
assert_contains "$ts_try_dry" "subtitle  #5 dvb [ger] -> copy" "TS second subtitle is detailed"
pass "Blu-ray TS 5.1(side) Opus handling is stable"

printf 'All video-compressor tests passed.\n'
