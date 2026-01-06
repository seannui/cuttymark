# Cuttymark

Cuttymark is a Rails application for analyzing video files, matching spoken content to search phrases, and generating edit lists to create logical, standalone clips containing those phrases.

## Features

- **Video Transcription**: Automatic speech-to-text using Whisper (local) or Gemini (cloud)
- **Semantic Search**: Find clips by meaning, not just keywords, using embeddings
- **Smart Clip Boundaries**: Automatically detect topic changes to create coherent clips
- **Multiple Export Formats**: FFmpeg commands, Adobe Premiere XML, Final Cut Pro FCPXML
- **Non-destructive**: Source videos are never modified

## System Requirements

- **macOS** (tested on Apple Silicon M3 Max)
- **Ruby 3.3+** (check `.ruby-version`)
- **Rails 8.1+**
- **PostgreSQL 17** with pgvector extension
- **FFmpeg** for video/audio processing
- **Whisper.cpp** for local transcription
- **Ollama** for local embeddings

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/seannui/cuttymark.git
cd cuttymark
```

### 2. Install Ruby Dependencies

```bash
bundle install
```

### 3. Install PostgreSQL 17 with pgvector

If you don't have PostgreSQL 17 installed:

```bash
brew install postgresql@17
brew services start postgresql@17
```

Install the pgvector extension:

```bash
brew install pgvector
```

Create the database and enable pgvector:

```bash
createdb cuttymark_development
psql cuttymark_development -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

### 4. Install FFmpeg

```bash
brew install ffmpeg
```

Verify installation:

```bash
ffmpeg -version
```

### 5. Install Whisper.cpp

Clone and build whisper.cpp:

```bash
cd ~/git  # or your preferred directory
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
make

# Download the large-v3 model (recommended for accuracy)
./models/download-ggml-model.sh large-v3
```

Build the server:

```bash
mkdir -p build && cd build
cmake ..
make whisper-server
```

The whisper server will be started via `Procfile.dev`.

### 6. Install Ollama

```bash
brew install ollama
```

Start Ollama and pull the embedding model:

```bash
ollama serve  # Run in background or separate terminal
ollama pull nomic-embed-text
```

Verify the model is available:

```bash
ollama list
```

You should see `nomic-embed-text` in the list.

### 7. (Optional) Configure Gemini API

As an alternative to local Whisper transcription, you can use Google's Gemini API for cloud-based transcription. Gemini offers:

- **Speaker diarization** (automatic speaker labels)
- **No local GPU required**
- **Fast processing** via cloud infrastructure
- **Low cost** (~$0.02 for a 1.5 hour video with Gemini Flash)

To use Gemini:

1. Get an API key from [Google AI Studio](https://aistudio.google.com/app/apikey)

2. Set the environment variable:

```bash
export GEMINI_API_KEY=your_api_key_here
```

3. (Optional) Set Gemini as the default transcription engine:

```bash
export TRANSCRIPTION_ENGINE=gemini
```

4. (Optional) Choose a specific model:

```bash
# Options: gemini-2.0-flash (default, fast/cheap), gemini-1.5-pro (higher quality)
export GEMINI_MODEL=gemini-2.0-flash
```

**Note:** For audio files over 20MB, the Gemini client automatically uses the File API for upload.

### 8. Configure the Database

Update `config/database.yml` if needed, then:

```bash
bin/rails db:create
bin/rails db:migrate
```

### 9. Start the Application

```bash
bin/dev
```

This starts:
- Rails server on port 3000
- Whisper server on port 3333

Visit `http://localhost:3000`

---

## Blackmagic RAW (.braw) File Support

FFmpeg cannot natively read `.braw` files. You have several options:

### Option A: DaVinci Resolve (Recommended)

The simplest and most reliable approach:

1. Download [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve) (free version)
2. Import your `.braw` files
3. Export as ProRes 422 or H.264 MP4 (4K recommended)
4. Import the converted files into Cuttymark

### Option B: Brawtool (Command Line)

[Brawtool](https://github.com/mikaelsundell/brawtool) is a command-line utility for extracting frames from `.braw` files on macOS.

#### Prerequisites

```bash
brew install cmake boost openimageio opencolorio
```

#### Download Blackmagic RAW SDK

1. Visit the [Blackmagic RAW](https://www.blackmagicdesign.com/products/blackmagicraw) page
2. Click "Download Blackmagic RAW SDK" and select "Mac OS X"
3. Install the SDK

#### Build Brawtool

```bash
cd ~/git
git clone https://github.com/mikaelsundell/brawtool.git
cd brawtool
mkdir build && cd build

# For Apple Silicon (M1/M2/M3)
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release -j 8
```

#### Usage Example

Extract frames and convert to MP4 via FFmpeg:

```bash
# Extract all frames as PNG
brawtool --outputdirectory ./frames --outputformat png input.braw

# Combine frames into video with FFmpeg
ffmpeg -framerate 24 -i frames/frame_%04d.png -c:v libx264 -crf 18 output.mp4
```

### Option C: braw-decode (Linux Only)

[braw-decode](https://github.com/AkBKukU/braw-decode) is a headless decoder that pipes directly to FFmpeg. Currently only supports Linux.

---

## Project Structure

```
storage/
├── sources/     # Original video files (read-only references)
├── proxies/     # Converted proxy files (4K MP4)
├── audio/       # Extracted audio for transcription
└── exports/     # Rendered clip outputs
```

## Configuration

Create a `.env` file for local configuration:

```bash
# Whisper server
WHISPER_HOST=127.0.0.1
WHISPER_PORT=3333

# Ollama
OLLAMA_HOST=127.0.0.1
OLLAMA_PORT=11434
OLLAMA_EMBED_MODEL=nomic-embed-text

# Storage paths (defaults to storage/ in Rails root)
CUTTYMARK_STORAGE_PATH=storage
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
```

Update the whisper path to match your installation.

### Background Jobs

Cuttymark uses Solid Queue for background job processing. Jobs include:
- Video transcription
- Embedding generation
- Clip rendering

## Troubleshooting

### pgvector extension not found

```bash
# Ensure pgvector is installed
brew install pgvector

# Connect to your database and enable it
psql cuttymark_development -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

### Whisper server connection refused

Ensure the whisper server is running:

```bash
# Check if port 3333 is in use
lsof -i :3333

# Start manually if needed
/path/to/whisper.cpp/build/bin/whisper-server \
  -m /path/to/models/ggml-large-v3.bin \
  --host 127.0.0.1 --port 3333 -t 16 -p 8 --convert
```

### Ollama model not found

```bash
# Ensure Ollama is running
ollama serve

# Pull the model
ollama pull nomic-embed-text

# Verify
ollama list
```

### FFmpeg not finding codecs

```bash
# Reinstall with all codecs
brew reinstall ffmpeg
```

## License

[Add your license here]

## Contributing

[Add contribution guidelines here]
