#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
LOG_FILE=""
WORK_DIR=""
PROJECT_DIR=""
TTS_ENDPOINT="http://localhost:8001"
VIDEO_PATH=""
TRANSCRIPT_JSON=""
ORIGINAL_DURATION_MS=0
TOTAL_SEGMENTS=0

# --- Logging ---
log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

# --- Function stubs ---

init_dirs() {
    local video_path="$1"
    local base_name
    base_name="$(basename "${video_path}")"

    PROJECT_DIR="./${base_name%.*}"
    WORK_DIR="${PROJECT_DIR}/work"

    log "Creating project directories under ${PROJECT_DIR}"
    mkdir -p "${WORK_DIR}/tts_out"
    mkdir -p "${WORK_DIR}/silence_gaps"
    mkdir -p "${WORK_DIR}/segments"

    LOG_FILE="${WORK_DIR}/pipeline.log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
}

transcribe() {
    log "=== Step: Whisper Transcription ==="
    log "Running whisper on: ${VIDEO_PATH}"

    local json_output="${WORK_DIR}/transcript.json"

    whisper "${VIDEO_PATH}" \
        --model small \
        --language Polish \
        --output_format json \
        --device cuda \
        --output_dir "${WORK_DIR}" \
        --word_timestamps True

    # Find the output JSON file (whisper names it after the input filebase)
    local base_name
    base_name="$(basename "${VIDEO_PATH%.*}")"

    # Whisper saves as: ${output_dir}/${base_name}.${output_format}
    json_output="${WORK_DIR}/${base_name}.json"

    if [[ ! -f "${json_output}" ]]; then
        err "Whisper output JSON not found: ${json_output}"
        err "Files in ${WORK_DIR}:"
        ls -la "${WORK_DIR}/" >&2
        exit 1
    fi

    # Validate JSON structure - check for segments with words
    local has_words
    has_words=$(jq -r 'if .words then "yes" elif .segments[0].words then "yes" else "no" end' "${json_output}" 2>/dev/null || echo "no")

    if [[ "${has_words}" != "yes" ]]; then
        err "JSON output does not contain word-level timestamps"
        exit 1
    fi

    log "Transcription complete: ${json_output}"

    # Store duration of original audio for verification
    local audio_dur
    audio_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${VIDEO_PATH}" 2>/dev/null)
    ORIGINAL_DURATION_MS=$(echo "${audio_dur}" | awk '{printf "%.0f", $1 * 1000}')
    log "Original audio duration: ${ORIGINAL_DURATION_MS}ms (${audio_dur}s)"

    TRANSCRIPT_JSON="${json_output}"
}

parse_segments() {
    log "=== Step: Parse Segments ==="
    log "Reading Whisper JSON: ${TRANSCRIPT_JSON}"

    if [[ ! -f "${TRANSCRIPT_JSON}" ]]; then
        err "Transcript JSON not found: ${TRANSCRIPT_JSON}"
        exit 1
    fi

    # Flatten all words from both possible JSON formats:
    #   - nested: .segments[].words[]
    #   - flat: .words[]
    # Then group consecutive words into sentences at punctuation boundaries (. ! ? ...)
    jq -r '
      [
        (if .segments then .segments[].words[] else empty end),
        (if .words then .words[] else empty end)
      ]
      | .[]
      | "\(.start * 1000 | floor)\t\(.end * 1000 | floor)\t\(.word)"
    ' "${TRANSCRIPT_JSON}" | \
    awk -F'\t' '
BEGIN {
    seg = 0
    text = ""
    seg_start = 0
}
{
    start_ms = $1
    end_ms = $2
    word = $3

    if (seg_start == 0) seg_start = start_ms

    if (text == "") text = word
    else text = text " " word

    # Check trailing punctuation (Polish sentence boundaries)
    if (word ~ /[.!?…]$/) {
        seg++
        dur = end_ms - seg_start
        # Safety: collapse internal tabs
        gsub(/\t/, " ", text)
        printf "%d\t%d\t%d\t%d\t%s\n", seg, seg_start, end_ms, dur, text
        seg_start = 0
        text = ""
    }
}
END {
    # Flush remaining words without punctuation
    if (text != "") {
        seg++
        dur = seg_start > 0 ? end_ms - seg_start : 0
        gsub(/\t/, " ", text)
        printf "%d\t%d\t%d\t%d\t%s\n", seg, seg_start, end_ms, dur, text
    }
}
    ' > "${WORK_DIR}/segments/segments.tsv"

    TOTAL_SEGMENTS=$(wc -l < "${WORK_DIR}/segments/segments.tsv")
    log "Parsed ${TOTAL_SEGMENTS} segments from transcript"

    if [[ "${TOTAL_SEGMENTS}" -eq 0 ]]; then
        err "No segments extracted — check Whisper JSON format"
        exit 1
    fi
}

generate_tts() {
    log "== Step: TTS Generation =="

    local segments_file="${WORK_DIR}/segments/segments.tsv"

    if [[ ! -f "${segments_file}" ]]; then
        err "Segments file not found: ${segments_file}"
        exit 1
    fi

    # Clear any previous metadata
    > "${WORK_DIR}/segments/tts_metadata.tsv"

    # Read each segment and generate TTS audio
    while IFS=$'\t' read -r seg_num start_ms end_ms orig_dur_ms text <&3; do
        local padded_num
        padded_num=$(printf "%03d" "${seg_num}")
        local tts_mp3="${WORK_DIR}/tts_out/segment_${padded_num}.mp3"
        local tts_wav="${WORK_DIR}/tts_out/segment_${padded_num}.wav"

        log "  Generating TTS for segment ${seg_num}: '${text}'"

        # Call Piper TTS endpoint
        local json_body
        json_body=$(jq -n --arg txt "${text}" '{"model": "tts-1", "input": $txt, "voice": "pl_male"}')
        curl -s -X POST "${TTS_ENDPOINT}/v1/audio/speech" \
            -H "Content-Type: application/json" \
            -d "${json_body}" \
            -o "${tts_mp3}" || {
                err "TTS request failed for segment ${seg_num}"
                exit 1
            }

        # Verify we got audio back
        if [[ ! -s "${tts_mp3}" ]]; then
            err "TTS output is empty for segment ${seg_num}"
            exit 1
        fi

        # Convert to WAV at 48kHz for consistent concatenation
        ffmpeg -y -i "${tts_mp3}" -acodec pcm_s16le -ar 48000 -ac 1 "${tts_wav}" >/dev/null 2>&1 || {
            err "Failed to convert segment ${seg_num} to WAV"
            exit 1
        }

        # Get actual TTS duration for gap calculation
        local tts_dur_ms
        tts_dur_ms=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${tts_wav}" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}')

        # Store metadata: seg_num, orig_start_ms, orig_end_ms, orig_dur_ms, tts_dur_ms
        echo "${seg_num}	${start_ms}	${end_ms}	${orig_dur_ms}	${tts_dur_ms}" >> "${WORK_DIR}/segments/tts_metadata.tsv"

        log "  Segment ${seg_num}: original=${orig_dur_ms}ms, TTS=${tts_dur_ms}ms"

        # Clean up MP3 to save space
        rm -f "${tts_mp3}"
    done 3< "${segments_file}"

    log "TTS generation complete: ${TOTAL_SEGMENTS} segments"
}

create_gaps() {
    log "== Step: Create Silence Gaps =="

    local metadata_file="${WORK_DIR}/segments/tts_metadata.tsv"

    if [[ ! -f "${metadata_file}" ]]; then
        err "TTS metadata not found: ${metadata_file}"
        exit 1
    fi

    local prev_end_ms=-1
    local seg_idx=0

    while IFS=$'\t' read -r seg_num orig_start_ms orig_end_ms orig_dur_ms tts_dur_ms <&3; do
        seg_idx=$((seg_idx + 1))
        local padded
        padded=$(printf "%03d" "${seg_idx}")

        # --- Inter-segment gap: silence from prev segment end to this segment start ---
        local inter_gap_ms=0
        if [[ ${seg_idx} -eq 1 ]]; then
            # First segment: gap from 0 to first speech onset (silent intro)
            inter_gap_ms=${orig_start_ms}
        else
            inter_gap_ms=$((orig_start_ms - prev_end_ms))
        fi

        if [[ ${inter_gap_ms} -gt 0 ]]; then
            local inter_gap_sec
            inter_gap_sec=$(echo "${inter_gap_ms}" | awk '{printf "%.3f", $1 / 1000}')
            local inter_gap_wav="${WORK_DIR}/silence_gaps/inter_${padded}.wav"
            ffmpeg -y -f lavfi -i "anullsrc=r=48000:cl=mono" -t "${inter_gap_sec}" -acodec pcm_s16le "${inter_gap_wav}" </dev/null >/dev/null 2>&1 || {
                err "Failed to generate inter-segment silence for segment ${seg_idx}"
                exit 1
            }
            log "  Segment ${seg_idx}: Inter-segment gap=${inter_gap_ms}ms"
        fi

        # --- Intra-segment gap: within this segment ---
        local gap_ms=$((orig_dur_ms - tts_dur_ms))

        if [[ "${gap_ms}" -lt 0 ]]; then
            log "  Segment ${seg_idx}: TTS is LONGER by $((tts_dur_ms - orig_dur_ms))ms - accepting overrun"
        elif [[ "${gap_ms}" -gt 0 ]]; then
            local gap_sec
            gap_sec=$(echo "${gap_ms}" | awk '{printf "%.3f", $1 / 1000}')
            local gap_wav="${WORK_DIR}/silence_gaps/gap_${padded}.wav"
            ffmpeg -y -f lavfi -i "anullsrc=r=48000:cl=mono" -t "${gap_sec}" -acodec pcm_s16le "${gap_wav}" </dev/null >/dev/null 2>&1 || {
                err "Failed to generate silence gap for segment ${seg_idx}"
                exit 1
            }
            local actual_gap_ms
            actual_gap_ms=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${gap_wav}" </dev/null 2>/dev/null | awk '{printf "%.0f", $1 * 1000}')
            log "  Segment ${seg_idx}: TTS=${tts_dur_ms}ms, Intra-gap=${actual_gap_ms}ms (${gap_ms}ms target)"
        else
            log "  Segment ${seg_idx}: No intra-segment gap needed (TTS matches original)"
        fi

        prev_end_ms=${orig_end_ms}
    done 3< "${metadata_file}"

    log "Silence gap creation complete"
}

concatenate_audio() {
    log "== Step: Audio Concatenation =="

    local concat_list="${WORK_DIR}/concat_list.txt"
    local final_wav="${WORK_DIR}/final_audio.wav"

    > "${concat_list}"

    local total_expected_ms=0

    for i in $(seq 1 ${TOTAL_SEGMENTS}); do
        local padded
        padded=$(printf "%03d" "${i}")

        # Inter-segment gap (before this segment)
        local inter_file="${WORK_DIR}/silence_gaps/inter_${padded}.wav"
        if [[ -f "${inter_file}" ]]; then
            echo "file '$(realpath "${inter_file}")'" >> "${concat_list}"
            local inter_dur
            inter_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${inter_file}" </dev/null 2>/dev/null | awk '{printf "%.0f", $1 * 1000}')
            total_expected_ms=$((total_expected_ms + inter_dur))
            log "  Added inter_${padded}"
        fi

        # TTS segment
        local seg_file="${WORK_DIR}/tts_out/segment_${padded}.wav"
        if [[ -f "${seg_file}" ]]; then
            echo "file '$(realpath "${seg_file}")'" >> "${concat_list}"
            local seg_dur
            seg_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${seg_file}" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}')
            total_expected_ms=$((total_expected_ms + seg_dur))
        else
            err "Missing segment file: ${seg_file}"
            exit 1
        fi

        # Intra-segment gap (after this segment)
        local gap_file="${WORK_DIR}/silence_gaps/gap_${padded}.wav"
        if [[ -f "${gap_file}" ]]; then
            echo "file '$(realpath "${gap_file}")'" >> "${concat_list}"
            local gap_dur
            gap_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${gap_file}" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}')
            total_expected_ms=$((total_expected_ms + gap_dur))
            log "  Added segment_${padded} + gap_${padded}"
        else
            log "  Added segment_${padded} (no intra gap)"
        fi
    done

    log "Concatenating ${TOTAL_SEGMENTS} segments + gaps..."

    ffmpeg -y -f concat -safe 0 -i "${concat_list}" -c copy "${final_wav}" </dev/null >/dev/null 2>&1 || {
        err "Concatenation failed"
        exit 1
    }

    local final_dur_ms
    final_dur_ms=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${final_wav}" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}')

    log "Final audio duration: ${final_dur_ms}ms (expected sum: ${total_expected_ms}ms)"
    log "Original audio duration: ${ORIGINAL_DURATION_MS}ms"

    local diff=$((final_dur_ms - ORIGINAL_DURATION_MS))
    if [[ ${diff} -lt 0 ]]; then diff=$((-diff)); fi

    if [[ ${diff} -gt 2000 ]]; then
        err "Duration mismatch: ${diff}ms difference (tolerance: 2000ms)"
        err "Final: ${final_dur_ms}ms vs Original: ${ORIGINAL_DURATION_MS}ms"
        exit 1
    fi

    log "Duration check PASSED: ${diff}ms difference"

    rm -f "${concat_list}"
}

merge_video() {
    log "=== Step: Video Merge ==="

    local final_wav="${WORK_DIR}/final_audio.wav"
    local output_mp4="${WORK_DIR}/output.mp4"

    if [[ ! -f "${final_wav}" ]]; then
        err "Final audio not found: ${final_wav}"
        exit 1
    fi
    if [[ ! -f "${VIDEO_PATH}" ]]; then
        err "Source video not found: ${VIDEO_PATH}"
        exit 1
    fi

    log "Merging video with new audio track..."

    # Replace audio, copy video codec, encode audio as AAC
    ffmpeg -y \
        -i "${VIDEO_PATH}" \
        -i "${final_wav}" \
        -c:v copy \
        -c:a aac \
        -b:a 192k \
        -map 0:v:0 \
        -map 1:a:0 \
        -shortest \
        "${output_mp4}" >/dev/null 2>&1 || {
            err "Video merge failed"
            exit 1
        }

    if [[ ! -f "${output_mp4}" ]]; then
        err "Output video was not created: ${output_mp4}"
        exit 1
    fi

    # Verify output
    local out_dur
    out_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${output_mp4}" 2>/dev/null)
    local out_dur_ms
    out_dur_ms=$(echo "${out_dur}" | awk '{printf "%.0f", $1 * 1000}')

    log "Output video duration: ${out_dur_ms}ms (${out_dur}s)"
    log "Original video duration: ${ORIGINAL_DURATION_MS}ms"

    local file_size
    file_size=$(du -h "${output_mp4}" | awk '{print $1}')
    log "Output file size: ${file_size}"

    log "Output: ${output_mp4}"
}

cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        err "Pipeline failed with exit code ${exit_code}"
        err "Check ${LOG_FILE} for details if available"
    fi
    exit ${exit_code}
}

main() {
    local video_path="$1"

    if [[ ! -f "${video_path}" ]]; then
        err "File not found: ${video_path}"
        exit 1
    fi
    if [[ ! -r "${video_path}" ]]; then
        err "File not readable: ${video_path}"
        exit 1
    fi

    VIDEO_PATH="$(realpath "${video_path}")"

    log "=== Starting TTS Video Audio Replacement ==="
    log "Input: ${video_path}"

    init_dirs "${video_path}"
    transcribe
    parse_segments
    generate_tts
    create_gaps
    concatenate_audio
    merge_video

    log "=== Pipeline Complete ==="
    log "Output: ${WORK_DIR}/output.mp4"
}

# --- Main ---
trap cleanup EXIT

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <video_path>"
    exit 1
fi

main "$1"
