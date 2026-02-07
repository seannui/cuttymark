# Cuttymark Installation Guide

## System Requirements

- **macOS** (tested on Apple Silicon M2/M3)
- **Ruby 3.3+** (check `.ruby-version`)
- **Rails 8.1+**
- **PostgreSQL 17** with pgvector extension
- **FFmpeg 8.0+** for video/audio processing
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

Verify installation (requires version 8.0+):

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
bin/rails db:schema:load:queue
```

### 9. Environment Configuration

Copy the example environment file and customize:

```bash
cp .env.example .env
```

Edit `.env` to configure:

```bash
# Database (optional - defaults work for local development)
# PGHOST=localhost
# PGUSER=your_username
# DATABASE_NAME=cuttymark_development

# Source video directory (default: storage/sources)
# Set this to use an external drive or different location
# CUTTYMARK_SOURCES_PATH=/Volumes/ExternalDrive/footage

# Whisper server
WHISPER_HOST=127.0.0.1
WHISPER_PORT=3333

# Ollama
OLLAMA_HOST=127.0.0.1
OLLAMA_PORT=11434
OLLAMA_EMBED_MODEL=nomic-embed-text

# Transcription engine (whisper or gemini)
# TRANSCRIPTION_ENGINE=whisper
# GEMINI_API_KEY=your_key_here

# BRAW decoder (optional - auto-detected)
# BRAW_DECODE_PATH=/path/to/braw-decode-metal
```

### 10. Start the Application

```bash
bin/dev
```

This starts:
- Rails server on port 3000
- Whisper server on port 3333
- Solid Queue for background jobs

Visit `http://localhost:3000`

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

### VS Code Ruby LSP with mise

If using mise for Ruby version management, configure VS Code:

```json
{
  "rubyLsp.rubyVersionManager": {
    "identifier": "mise"
  }
}
```

Or install the "mise" VS Code extension by jdx.


### Reset dev datastores

```bash
rails db:drop db:create db:migrate && bin/rails db:schema:load:queue
```