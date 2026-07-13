#!/usr/bin/env sh
set -eu

INPUT_ROOT=${MEDIA_INPUT_ROOT:-/media/inbox}
OUTPUT_ROOT=${MEDIA_OUTPUT_ROOT:-/media/generated}
WORK_ROOT=${MEDIA_WORK_ROOT:-$(dirname "$OUTPUT_ROOT")/.work}
LADDER_FILE=${MEDIA_LADDER_FILE:-/config/encoding-ladder.tsv}
ONLY=${MEDIA_ONLY:-}
FORCE=${MEDIA_FORCE:-0}
SEGMENT_SECONDS=${MEDIA_SEGMENT_SECONDS:-2}
FRAME_RATE=${MEDIA_FRAME_RATE:-30}
POSTER_SECOND=${MEDIA_POSTER_SECOND:-1}
STORYBOARD_INTERVAL=${MEDIA_STORYBOARD_INTERVAL:-5}
PRESET=${MEDIA_FFMPEG_PRESET:-veryfast}

fail() {
  echo "media-ingest: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'
}

is_selected() {
  file_name=$1
  stem=$2
  id=$3
  [ -z "$ONLY" ] || [ "$ONLY" = "$file_name" ] || [ "$ONLY" = "$stem" ] || [ "$ONLY" = "$id" ]
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required"
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
[ -d "$INPUT_ROOT" ] || fail "input directory does not exist: $INPUT_ROOT"
[ -f "$LADDER_FILE" ] || fail "encoding ladder does not exist: $LADDER_FILE"
is_number "$SEGMENT_SECONDS" || fail "MEDIA_SEGMENT_SECONDS must be an integer"
is_number "$FRAME_RATE" || fail "MEDIA_FRAME_RATE must be an integer"
is_number "$STORYBOARD_INTERVAL" || fail "MEDIA_STORYBOARD_INTERVAL must be an integer"
[ "$SEGMENT_SECONDS" -gt 0 ] || fail "MEDIA_SEGMENT_SECONDS must be greater than zero"
[ "$FRAME_RATE" -gt 0 ] || fail "MEDIA_FRAME_RATE must be greater than zero"
[ "$STORYBOARD_INTERVAL" -gt 0 ] || fail "MEDIA_STORYBOARD_INTERVAL must be greater than zero"

mkdir -p "$OUTPUT_ROOT" "$WORK_ROOT"
SEEN_FILE="$WORK_ROOT/.seen.$$"
MATCHED=0
: > "$SEEN_FILE"
trap 'rm -f "$SEEN_FILE"' EXIT HUP INT TERM

process_file() {
  input=$1
  file_name=${input##*/}
  stem=${file_name%.*}
  checksum=$(sha256sum "$input" | awk '{print $1}')
  id=$(slugify "$stem")
  if [ -z "$id" ]; then
    id="asset-$(printf '%s' "$checksum" | cut -c1-12)"
  fi

  is_selected "$file_name" "$stem" "$id" || return 0
  MATCHED=1

  if grep -Fx "$id" "$SEEN_FILE" >/dev/null 2>&1; then
    fail "two source files resolve to the same asset id '$id'; rename one of them"
  fi
  printf '%s\n' "$id" >> "$SEEN_FILE"

  pipeline_checksum=$(
    {
      printf 'source=%s\n' "$checksum"
      printf 'segment=%s\nframe_rate=%s\npreset=%s\nposter=%s\nstoryboard=%s\n' \
        "$SEGMENT_SECONDS" "$FRAME_RATE" "$PRESET" "$POSTER_SECOND" "$STORYBOARD_INTERVAL"
      sha256sum "$LADDER_FILE"
      sha256sum "$0"
      ffmpeg -version | head -n 1
    } | sha256sum | awk '{print $1}'
  )

  final_dir="$OUTPUT_ROOT/$id"
  if [ "$FORCE" != "1" ] && [ -f "$final_dir/.ingest.sha256" ] &&
     [ "$(cat "$final_dir/.ingest.sha256")" = "$pipeline_checksum" ]; then
    log "Skipping unchanged asset and pipeline: $id"
    return 0
  fi

  work_dir="$WORK_ROOT/$id.$$"
  rm -rf "$work_dir"
  mkdir -p \
    "$work_dir/progressive" \
    "$work_dir/encoded" \
    "$work_dir/hls" \
    "$work_dir/dash" \
    "$work_dir/storyboard" \
    "$work_dir/subtitles"

  log "Probing $file_name"
  ffprobe -v error -show_format -show_streams -of json "$input" > "$work_dir/probe.json"

  stored_dimensions=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0:s=x "$input")
  [ -n "$stored_dimensions" ] || fail "no video stream found in $file_name"
  stored_width=${stored_dimensions%x*}
  stored_height=${stored_dimensions#*x}

  rotation=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream_tags=rotate:stream_side_data=rotation \
    -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | tail -n 1 || true)
  case "$rotation" in
    90|-90|270|-270)
      source_width=$stored_height
      source_height=$stored_width
      ;;
    *)
      source_width=$stored_width
      source_height=$stored_height
      ;;
  esac

  # Use the largest centered, even-sized crop with an exact 9:16 ratio.
  crop_dims=$(awk -v w="$source_width" -v h="$source_height" '
    BEGIN {
      unit = int(w / 9);
      height_unit = int(h / 16);
      if (height_unit < unit) unit = height_unit;
      unit = int(unit / 2) * 2;
      if (unit < 2) exit 1;
      print unit * 9 "x" unit * 16;
    }
  ') || fail "video is too small for an even 9:16 crop: $file_name"
  crop_width=${crop_dims%x*}
  crop_height=${crop_dims#*x}

  source_short=$crop_width
  crop_filter="crop=$crop_width:$crop_height,"

  if ffprobe -v error -select_streams a:0 -show_entries stream=index \
      -of csv=p=0 "$input" | grep -q .; then
    has_audio=1
  else
    has_audio=0
  fi

  video_duration=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$input" | head -n 1)
  case "$video_duration" in
    ''|N/A)
      video_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input" | head -n 1)
      ;;
  esac
  if ! awk -v value="$video_duration" 'BEGIN { exit !(value + 0 > 0) }'; then
    video_duration=
  fi

  gop=$((FRAME_RATE * SEGMENT_SECONDS))

  log "Creating progressive MP4"
  set -- ffmpeg -hide_banner -loglevel warning -nostdin -y -i "$input" \
    -map 0:v:0
  if [ "$has_audio" -eq 1 ]; then
    set -- "$@" -map 0:a:0
  fi
  set -- "$@" \
    -vf "${crop_filter}scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1,format=yuv420p" \
    -c:v libx264 -preset "$PRESET" -profile:v main \
    -r "$FRAME_RATE" -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
    -metadata:s:v:0 rotate=0
  if [ "$has_audio" -eq 1 ]; then
    set -- "$@" -c:a aac -b:a 128k -ac 2 -ar 48000 -af apad -shortest
  fi
  set -- "$@" -movflags +faststart "$work_dir/progressive/video.mp4"
  "$@"
  ffprobe -v error -show_format -show_streams -of json \
    "$work_dir/progressive/video.mp4" > "$work_dir/output-probe.json"

  audio_path=
  if [ "$has_audio" -eq 1 ]; then
    log "Creating reusable AAC audio track"
    audio_path="$work_dir/encoded/audio.m4a"
    set -- ffmpeg -hide_banner -loglevel warning -nostdin -y -i "$input" \
      -map 0:a:0 -vn -c:a aac -b:a 128k -ac 2 -ar 48000
    if [ -n "$video_duration" ]; then
      set -- "$@" -af apad -t "$video_duration"
    fi
    set -- "$@" -movflags +faststart "$audio_path"
    "$@"
  fi

  renditions="$work_dir/renditions.tsv"
  : > "$renditions"
  dimensions_seen="$work_dir/.dimensions"
  : > "$dimensions_seen"

  log "Encoding adaptive bitrate ladder"
  tab=$(printf '\t')
  while IFS="$tab" read -r configured_name configured_short bitrate maxrate bufsize; do
    case "$configured_name" in ''|'#'*) continue ;; esac
    is_number "$configured_short" || fail "invalid short side in $LADDER_FILE: $configured_short"

    target_short=$configured_short
    if [ "$target_short" -gt "$source_short" ]; then
      if [ -s "$dimensions_seen" ]; then
        continue
      fi
      target_short=$source_short
    fi
    output_name="${target_short}p"

    target_width=$target_short
    target_height=$(awk -v s="$target_short" \
      'BEGIN { value=int(s*16/9/2)*2; if (value < 2) value=2; print value }')

    dimensions="${target_width}x${target_height}"
    if grep -Fx "$dimensions" "$dimensions_seen" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\n' "$dimensions" >> "$dimensions_seen"

    output="$work_dir/encoded/video-$output_name.mp4"
    ffmpeg -hide_banner -loglevel warning -nostdin -y -i "$input" \
      -map 0:v:0 -an \
      -vf "${crop_filter}scale=${target_width}:${target_height}:flags=lanczos,setsar=1,format=yuv420p" \
      -c:v libx264 -preset "$PRESET" -profile:v main \
      -x264opts "sar=1/1" \
      -r "$FRAME_RATE" -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
      -force_key_frames "expr:gte(t,n_forced*${SEGMENT_SECONDS})" \
      -b:v "$bitrate" -maxrate "$maxrate" -bufsize "$bufsize" \
      -metadata:s:v:0 rotate=0 \
      -movflags +faststart "$output"

    actual_dimensions=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0:s=x "$output")
    actual_width=${actual_dimensions%x*}
    actual_height=${actual_dimensions#*x}
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$output_name" "$actual_width" "$actual_height" "$bitrate" "$maxrate" "$output" >> "$renditions"
  done < "$LADDER_FILE"

  [ -s "$renditions" ] || fail "no renditions were generated for $file_name"

  log "Packaging HLS ABR with fragmented MP4 segments"
  master="$work_dir/hls/master.m3u8"
  {
    echo '#EXTM3U'
    echo '#EXT-X-VERSION:7'
    echo '#EXT-X-INDEPENDENT-SEGMENTS'
  } > "$master"

  while IFS="$tab" read -r name width height bitrate maxrate video_path; do
    variant_dir="$work_dir/hls/$name"
    mkdir -p "$variant_dir"
    set -- ffmpeg -hide_banner -loglevel warning -nostdin -y -i "$video_path"
    if [ -n "$audio_path" ]; then
      set -- "$@" -i "$audio_path" -map 0:v:0 -map 1:a:0
    else
      set -- "$@" -map 0:v:0
    fi
    set -- "$@" -c copy -f hls \
      -hls_time "$SEGMENT_SECONDS" -hls_playlist_type vod \
      -hls_segment_type fmp4 -hls_flags independent_segments \
      -hls_fmp4_init_filename init.mp4 \
      -hls_segment_filename "$variant_dir/segment-%05d.m4s" \
      "$variant_dir/playlist.m3u8"
    "$@"

    bandwidth=$maxrate
    average_bandwidth=$bitrate
    if [ -n "$audio_path" ]; then
      bandwidth=$((maxrate + 128000))
      average_bandwidth=$((bitrate + 128000))
    fi
    printf '#EXT-X-STREAM-INF:BANDWIDTH=%s,AVERAGE-BANDWIDTH=%s,RESOLUTION=%sx%s,FRAME-RATE=%s\n' \
      "$bandwidth" "$average_bandwidth" "$width" "$height" "$FRAME_RATE" >> "$master"
    printf '%s/playlist.m3u8\n' "$name" >> "$master"
  done < "$renditions"

  log "Packaging DASH ABR"
  set -- ffmpeg -hide_banner -loglevel warning -nostdin -y
  input_index=0
  while IFS="$tab" read -r _name _width _height _bitrate _maxrate video_path; do
    set -- "$@" -i "$video_path"
    input_index=$((input_index + 1))
  done < "$renditions"
  audio_index=$input_index
  if [ -n "$audio_path" ]; then
    set -- "$@" -i "$audio_path"
  fi

  map_index=0
  while [ "$map_index" -lt "$input_index" ]; do
    set -- "$@" -map "${map_index}:v:0"
    map_index=$((map_index + 1))
  done
  if [ -n "$audio_path" ]; then
    set -- "$@" -map "${audio_index}:a:0"
  fi

  adaptation_sets="id=0,streams=v"
  if [ -n "$audio_path" ]; then
    adaptation_sets="$adaptation_sets id=1,streams=a"
  fi
  # shellcheck disable=SC2016
  set -- "$@" -c copy -f dash \
    -seg_duration "$SEGMENT_SECONDS" \
    -use_template 1 -use_timeline 1 \
    -adaptation_sets "$adaptation_sets" \
    -init_seg_name 'init-$RepresentationID$.m4s' \
    -media_seg_name 'chunk-$RepresentationID$-$Number%05d$.m4s' \
    "$work_dir/dash/manifest.mpd"
  "$@"

  log "Extracting poster and timeline previews"
  ffmpeg -hide_banner -loglevel warning -nostdin -y \
    -ss "$POSTER_SECOND" -i "$input" -map 0:v:0 -frames:v 1 \
    -vf "${crop_filter}scale='min(1280,iw)':-2:flags=lanczos" \
    -q:v 2 -update 1 "$work_dir/poster.jpg" || true
  if [ ! -s "$work_dir/poster.jpg" ]; then
    ffmpeg -hide_banner -loglevel warning -nostdin -y \
      -i "$input" -map 0:v:0 -frames:v 1 \
      -vf "${crop_filter}scale='min(1280,iw)':-2:flags=lanczos" \
      -q:v 2 -update 1 "$work_dir/poster.jpg"
  fi

  ffmpeg -hide_banner -loglevel warning -nostdin -y -i "$input" \
    -map 0:v:0 -vf "${crop_filter}fps=1/${STORYBOARD_INTERVAL},scale=320:-2:flags=lanczos" \
    -q:v 4 "$work_dir/storyboard/frame-%05d.jpg"

  input_dir=${input%/*}
  copied_subtitles=0
  for subtitle in "$input_dir/$stem".*.vtt "$input_dir/$stem".vtt; do
    [ -f "$subtitle" ] || continue
    subtitle_name=${subtitle##*/}
    if [ "$subtitle_name" = "$stem.vtt" ]; then
      language=und
    else
      language=${subtitle_name#"$stem".}
      language=${language%.vtt}
      language=$(slugify "$language")
      [ -n "$language" ] || language=und
    fi
    cp "$subtitle" "$work_dir/subtitles/$language.vtt"
    copied_subtitles=$((copied_subtitles + 1))
  done
  if [ "$copied_subtitles" -eq 0 ]; then
    rmdir "$work_dir/subtitles"
  fi

  cut -f1-5 "$renditions" > "$work_dir/renditions.public.tsv"
  mv "$work_dir/renditions.public.tsv" "$renditions"
  rm -f "$dimensions_seen"

  printf '%s\n' "$checksum" > "$work_dir/.source.sha256"
  printf '%s\n' "$pipeline_checksum" > "$work_dir/.ingest.sha256"
  printf '%s\n' "$file_name" > "$work_dir/.source-name"

  rm -rf "$final_dir.previous"
  if [ -d "$final_dir" ]; then
    mv "$final_dir" "$final_dir.previous"
  fi
  mv "$work_dir" "$final_dir"
  rm -rf "$final_dir.previous"
  log "Published asset: $id"
}

found=0
for input in "$INPUT_ROOT"/*; do
  [ -f "$input" ] || continue
  case "$input" in
    *.mp4|*.MP4|*.mov|*.MOV|*.mkv|*.MKV|*.webm|*.WEBM|*.m4v|*.M4V)
      found=1
      process_file "$input"
      ;;
  esac
done

if [ -n "$ONLY" ] && [ "$MATCHED" -eq 0 ]; then
  fail "no source video matched MEDIA_ONLY=$ONLY"
fi

if [ "$found" -eq 0 ]; then
  echo "No video files found in $INPUT_ROOT"
  echo "Supported extensions: mp4, mov, mkv, webm, m4v"
fi
