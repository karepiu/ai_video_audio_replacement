# TTS Video Synchronization Script - Implementation Guidance

# Constraints
- **Use ONLY bash** - No Python, no other languages
- **Keep it simple** - Don't add unnecessary complexity
- **Minimal parsing** - Use existing file formats as-is when possible
- **No extra dependencies** - Use standard Unix tools (awk, sed, grep)
- **No extra operations** - Each step should only do what is neccessary for that particular step and nothing else
- **No extra software** - You already have everything you need installed. No need to install anything. 

## Tools & Services

### Transcription
- **Tool:** Whisper (locally installed)
- **Purpose:** Generate transcript and timestamps from video audio
- **Output:** CSV file with timing information for each spoken segment
- **Usage:**  whisper "$VIDEO_IN" --model small --language Polish --output_format csv --device cuda --output_dir "$PROJECT_DIR" --word_timestamps True

### Voice Generation
- **Service:** Piper TTS
- **Endpoint:** `http://localhost:8001`
- **Purpose:** Generate natural-sounding speech from text
- **Usage:** curl -s -X POST "http://localhost:8001/v1/audio/speech" -H "Content-Type: application/json" -d "{\"model\": \"tts-1\", \"input\": \"$CLEAN_TEXT\", \"voice\": \"pl_male\"}"

### Core Operation Principles 

Before you start prepare plan.md. Devide whole processes into the tasks and specify them directly in the plan.md .
Your first task should always be preparing a most basic version of the whole solution - at this step you can ommit all validation or structures as the goal is for it to work. 
Start with single script. Update the original script if you extract some logic to separate file.
Complete task one by one. Check if each tasks was completed successfully both by running it seperately and in the chain with previous tasks. 
Mark completed tasks as such in the plan.md before you go to the next one.
All generated files should be stored in project dir under work dir. Project dir should be derived from input file name for easy readability.
Ask for confirmation before moving to the next task. Keep plan.md in the context. Whole solution needs to be runable by ./run.sh

# Sisyphus Custom Instructions
- Do not test or validate or write any code yourself. Always use subagents. 
- Always ask subagents to summarize the failed attempts and put that information in plan.md 
- If subagent fails 2 times stop and trigger an `Oracle` consultation to analyze why the logic is failing.

