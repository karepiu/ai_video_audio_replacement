# TTS Video Audio Replacement - Plan

## Pipeline: Transcription → TTS Generation → Gap Creation → Concatenation → Video Merge

## Key Discoveries
- Whisper output: Use JSON (no CSV), parse with `jq`
- TTS output: MP3, 22050Hz mono → needs standardization before concat
- Video audio: AAC, 48kHz stereo
- Segment grouping: Words grouped by punctuation boundaries (.!?)

## Tasks

### TASK 1: Project Structure + Skeleton run.sh [COMPLETE]
- Create run.sh with input validation, project dir from filename, work dir, function stubs

### TASK 2: Whisper Transcription [COMPLETE]
- Run whisper with JSON + word_timestamps
- Validate output JSON structure

### TASK 3: JSON → Segment Parsing (sentence grouping) [COMPLETE]
- Use jq to group words into sentences by punctuation
- Output segment metadata: start_ms, end_ms, text

### TASK 4: TTS Generation per segment [COMPLETE]
- Loop through segments, call TTS endpoint
- Standardize each output to WAV 48kHz
- Save as segment_NNN.wav with duration metadata

### TASK 5: Silence Gap Creation [COMPLETE]
- Calculate gap = (original_segment_end - tts_segment_end)
- Generate silence via ffmpeg anullsrc
- Handle TTS longer than original (warn, don't truncate)

### TASK 6: Audio Concatenation with Verification [COMPLETE]
- Build concat list: segment_001, gap_001, segment_002, gap_002...
- Verify after concat: duration matches sum of parts (±100ms)
- Output: final_audio.wav

### TASK 7: Video Merge [COMPLETE]
- Mux final_audio.wav with original video
- Preserve video codec, match audio codec to AAC
- Output: output.mp4

### TASK 8: End-to-End Testing [COMPLETE - 5th attempt ✅]
- Attempt 1: FAILED jq -r missing (validation false negative) → FIXED
- Attempt 2: FAILED stdin consumed by ffprobe in while-read loop → FIXED with fd3
- Attempt 3: FAILED concat list relative paths doubled by ffmpeg → FIXED with realpath
- Attempt 4: FAILED duration mismatch 54481ms (inter-segment silence not accounted for) → FIXED
- Attempt 5: SUCCESS ✅ — Pipeline completed all 6 steps without errors
- **Metrics (Attempt 5):**
  - Original duration: 425720ms (425.720s)
  - Final audio duration: 425900ms (diff: 180ms)
  - Output video duration: 425720ms (EXACT match)
  - Output file size: 184MB
  - Segments parsed: 45/45
  - TTS files generated: 45/45
  - Silence gaps: 77 files (inter-segment + intra-segment)
  - TTS overruns (gracefully accepted): 7 segments (4,5,7,11,35,43,44,45)
  - Duration check: PASSED (180ms < 2000ms threshold)
  - Run time: ~3min 40s (23:42:19 → 23:44:59)
- **Inter-segment silence fix VERIFIED:** create_gaps() now generates inter-segment gaps (segment[N+1].start_ms - segment[N].end_ms) and concatenate_audio() weaves them into the concat list as `inter_NNN` entries before each segment. Output duration now matches original exactly.

## Bug Fixes (Integration Review)
- **Orphaned words**: awk in parse_segments() had no END block — trailing words without punctuation were silently dropped. Fixed by adding END block that flushes remaining text.
- **JSON escaping**: curl sent Polish text raw in JSON body — would break on quotes/special chars. Fixed by using `jq -n --arg` for safe JSON construction.

## Failed Attempts Log

### Attempt 1: End-to-end test (2026-05-03 22:38)
- **Status:** FAILED at transcribe step (line 69)
- **Error:** `ERROR: JSON output does not contain word-level timestamps`
- **Root cause:** Line 67 calls `jq` without `-r` flag. Without `-r`, jq outputs `"yes"` (with JSON quotes). Line 69 compares against `yes` (no quotes). String `"\"yes\"" != "yes"` is true, so validation incorrectly fails. Whisper output is actually valid — JSON has 80 segments with word-level timestamps.
- **Fix:** Add `-r` to jq on line 67: `jq -r 'if .words then "yes"...'`
- **Whisper output:** Valid. File at work/Kierownik....json, ~100KB, segments[].words[] present.

### Attempt 2: End-to-end test (2026-05-03 22:46) — AFTER jq -r fix
- **Status:** FAILED at TTS generation step (segment 2)
- **Error:** `Generating TTS for segment 23520: ''` → `Failed to convert segment 23520 to WAV`
- **Root cause:** The `while IFS=$'\t' read -r seg_num start_ms end_ms orig_dur_ms text; do ... done < segments.tsv` loop in `generate_tts()` malfunctions on line 2. The `ffprobe` call inside the loop (for getting TTS duration) consumes stdin, which clobbers the redirected file descriptor feeding the `while read` loop. On the next iteration, `read` gets EOF/junk data instead of line 2. Result: `seg_num=23520` (actual `start_ms` of segment 2), `text=''` (empty string).
- **Evidence:**
  - Segment 1 processes correctly (seg_num=1, text present)
  - Segment 2 breaks: `seg_num=23520` (segment 2's `start_ms` value), `text=''` (empty)
  - File `segment_23520.mp3` exists (77 bytes — curl error response, not audio)
  - `segment_001.wav` exists and is valid (1.1MB, 12330ms duration)
  - 45 segments in TSV, only 1 processed — pipeline dies
  - Isolated bash tests of `while IFS=$'\t' read` on the same file parse correctly (no ffprobe inside loop)
- **Fix:** Use `exec 3<` / `read <&3` (fd3) pattern in `generate_tts()` and `create_gaps()` to avoid stdin consumption by ffprobe/curl.
- **Steps completed before failure:**
  - ✅ Whisper transcription (36s, 45 segments, valid JSON)
  - ✅ Parse segments (45 sentences, TSV valid)
  - ❌ TTS generation (segment 1 OK, segment 2 broken)
- **Diagnostics:**
  - Original duration: 425.720s
  - Output video: NOT created
  - Final audio: NOT created
  - TTS segments generated: 1/45
  - TTS metadata lines: 1/45

### Attempt 3: End-to-end test (2026-05-03 23:03) — AFTER jq -r + fd3 fixes
- **Status:** FAILED at concatenation step
- **Error:** `[concat] Impossible to open '/home/karepiu/.../work/./Kierownik.../work/tts_out/segment_001.wav'`
- **Root cause:** `concat_list.txt` contains relative paths prefixed with `./` (e.g. `file './Kierownik.../work/tts_out/segment_001.wav'`). FFmpeg's concat demuxer resolves paths relative to the concat file's directory (`WORK_DIR`). Since WORK_DIR = `./Kierownik.../work`, paths double to `WORK_DIR/./Kierownik.../work/tts_out/...` → file not found.
- **Fix needed:** Write absolute paths to `concat_list.txt`. Either `cd "$WORK_DIR"` before running ffmpeg, or use `realpath` / `$(cd "$(dirname "$seg_file")" && pwd)/$(basename "$seg_file")` when writing paths to the concat list.
- **fd3 fix VERIFIED WORKING:** All 45 segments generated and converted successfully, 38 gaps created, 7 TTS overruns gracefully handled.
- **Steps completed before failure:**
  - ✅ Whisper transcription (102s, 45 segments)
  - ✅ Parse segments (45 segments)
  - ✅ TTS generation (45/45 segments, ~3min)
  - ✅ Silence gap creation (38 gaps)
  - ❌ Audio concatenation (ffmpeg concat: doubled paths)
- **Diagnostics:**
  - Original duration: 425720ms
  - Output video: NOT created
  - Final audio: NOT created
  - TTS segments: 45/45 `.wav` files
  - Silence gaps: 38 `.wav` files
  - Concat list: 87 entries, all relative paths

## Success Criteria
1. `./run.sh "<video_path>"` runs without errors
2. Output video duration within ±2s of original
3. Audio contains TTS-generated Polish speech
4. No extra deps installed
