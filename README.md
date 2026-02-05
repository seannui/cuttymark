# Cuttymark

Cuttymark is a Rails application for analyzing video files, matching spoken content to search phrases, and generating edit lists to create logical, standalone clips containing those phrases.

## Features

- **Video Transcription**: Automatic speech-to-text using Whisper (local) or Gemini (cloud)
- **Semantic Search**: Find clips by meaning, not just keywords, using embeddings
- **Smart Clip Boundaries**: Automatically detect topic changes to create coherent clips
- **Multiple Export Formats**: FFmpeg commands, Adobe Premiere XML, Final Cut Pro FCPXML
- **Non-destructive**: Source videos are never modified

## Quick Start

See **[INSTALL.md](INSTALL.md)** for detailed installation instructions.

```bash
# After installation, start the app
bin/dev

# Process a video file
rake cm:process[/path/to/video.mp4]
```

Visit `http://localhost:3000`

## Project Structure

```
storage/
├── sources/     # Default location for source videos (configurable via CUTTYMARK_SOURCES_PATH)
├── proxies/     # Converted proxy files (4K MP4)
├── audio/       # Extracted audio for transcription
└── exports/     # Rendered clip outputs
```

Source videos can be stored on an external drive by setting `CUTTYMARK_SOURCES_PATH` in your `.env` file.

## Rake Tasks

Cuttymark provides custom rake tasks for setup, content ingestion, and processing. All tasks are in the `cm:` namespace.

### Video Processing

| Task | Description |
|------|-------------|
| `cm:process[path,project]` | Process a single video through the full pipeline (import, transcribe, embed) |
| `cm:process_all[project,include_braw]` | Process all unprocessed videos in sources directory (BRAW skipped by default) |
| `cm:reprocess[video_id,engine]` | Re-transcribe and re-embed a single video |
| `cm:reprocess_all[project]` | Reprocess all videos from scratch |
| `cm:retry[video_id]` | Retry a failed video |

**Examples:**
```bash
# Process a single video
rake cm:process[/path/to/video.mp4]
rake cm:process[/path/to/video.mp4,"My Project"]

# Process all videos in sources directory (skips .braw files)
rake cm:process_all
rake cm:process_all["My Project"]

# Include BRAW files in processing
rake cm:process_all["My Project",true]

# Reprocess with a specific engine
rake cm:reprocess[123,gemini]
```

### BRAW Conversion

| Task | Description |
|------|-------------|
| `cm:convert_braw[folder,dry_run,recursive,encoder]` | Convert BRAW files to MP4 |
| `cm:convert_braw_recursive[folder,dry_run,encoder]` | Recursively convert all BRAW files |

**Examples:**
```bash
# Dry run (preview what would be converted)
rake cm:convert_braw[/path/to/folder,true]

# Convert with hardware encoding (default)
rake cm:convert_braw[/path/to/folder]

# Recursive conversion
rake cm:convert_braw[/path/to/folder,false,true]

# Force software encoding
rake cm:convert_braw[/path/to/folder,false,false,software]
```

For detailed BRAW setup instructions, see **[doc/braw_to_mp4_conversion.md](doc/braw_to_mp4_conversion.md)**.

### Job Management

| Task | Description |
|------|-------------|
| `cm:jobs:status` | Show job queue status |
| `cm:jobs:clear` | Clear pending jobs (keeps completed/failed) |
| `cm:jobs:clear_all` | Clear all jobs including completed |
| `cm:jobs:clear_failed` | Clear failed jobs |
| `cm:jobs:retry_failed` | Retry all failed jobs |
| `cm:wait_for_jobs` | Wait for all processing jobs to complete |

**Examples:**
```bash
# Check queue status
rake cm:jobs:status

# Retry all failed jobs
rake cm:jobs:retry_failed

# Wait for batch processing to complete
rake cm:wait_for_jobs
```

### Transcript Maintenance

| Task | Description |
|------|-------------|
| `cm:search[video_id,query]` | Search a video transcript for a phrase |
| `cm:clean_hallucinations[video_id]` | Remove hallucinated segments from transcript |
| `cm:cleanup_text[transcript_id]` | Clean up broken words using LLM |

**Examples:**
```bash
# Search for a phrase in a video
rake cm:search[123,"climate change"]

# Clean hallucinations from a transcript
rake cm:clean_hallucinations[123]
```

### Utilities

| Task | Description |
|------|-------------|
| `cm:scan_mp4[directory]` | Scan directory for MP4 files and export metadata to CSV |

**Example:**
```bash
rake cm:scan_mp4[/Volumes/drive/footage]
# Output: tmp/mp4_scan_20260205_123456.csv
```

## Configuration

Create a `.env` file for local configuration (see `.env.example`):

```bash
# Source video directory (default: storage/sources)
CUTTYMARK_SOURCES_PATH=/Volumes/ExternalDrive/footage

# Whisper server
WHISPER_HOST=127.0.0.1
WHISPER_PORT=3333

# Ollama
OLLAMA_HOST=127.0.0.1
OLLAMA_PORT=11434
OLLAMA_EMBED_MODEL=nomic-embed-text
```

## Running Tests

```bash
bin/rails test
```

To run tests without parallelism:

```bash
RAILS_TEST_WORKERS=1 bin/rails test
```

## Development

### Procfile.dev

The development Procfile starts all required services:

```
web: bin/rails server -p 3000
whisper: /path/to/whisper.cpp/build/bin/whisper-server -m /path/to/models/ggml-large-v3.bin --host 127.0.0.1 --port 3333 -t 16 -p 8 --convert
jobs: bin/rails solid_queue:start
```

Update the whisper path to match your installation.

### Background Jobs

Cuttymark uses Solid Queue for background job processing. Jobs include:
- Video transcription
- Embedding generation
- Clip rendering

Monitor jobs at: `http://localhost:3000/jobs`

## License

[Add your license here]

## Contributing

[Add contribution guidelines here]
