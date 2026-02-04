# BRAW to 4K MP4 Conversion Guide

This guide explains how to convert Blackmagic RAW (.braw) files to 4K MP4 format using command-line tools.

## Overview

FFmpeg does not natively support BRAW (Blackmagic RAW). BRAW is a proprietary format requiring the Blackmagic RAW SDK for decoding. This guide uses **braw-decode-macOS** to decode BRAW files and pipe the output to FFmpeg for encoding.

## Prerequisites

- macOS 10.14 or later
- Xcode Command Line Tools (`xcode-select --install`)
- **FFmpeg 8.0 or later** (`brew install ffmpeg`)
  - Run `ffmpeg -version` to check your version
  - If below 8.0, run `brew upgrade ffmpeg`

## Setup

### Step 1: Download Blackmagic RAW SDK

1. Go to https://www.blackmagicdesign.com/developer/products/braw
2. Download the macOS SDK (requires free registration)
3. Mount the DMG and locate the SDK files

### Step 2: Clone and Build braw-decode-macOS

```bash
# Clone the repository
cd ~/git  # or preferred location
git clone https://github.com/meisa233/braw-decode-macOS.git
cd braw-decode-macOS

# Copy SDK files from downloaded SDK
# - Copy "Include" folder to project root
# - Copy "Libraries" folder to project root

# Build (the binary will be created at ../braw-decode)
make

# Verify the binary was created
ls -la ../braw-decode
```

**Note**: The Makefile places the compiled `braw-decode` binary one directory up from `braw-decode-macOS/` (i.e., at `~/git/braw-decode`).

### Step 3: Test with a Single File

**Important**: Run braw-decode from the braw-decode-macOS directory (where the Libraries folder is located).

```bash
cd /path/to/braw-decode-macOS

# Get video info from a BRAW file
./braw-decode -n /path/to/file.braw

# Get FFmpeg parameters (resolution, framerate, pixel format)
./braw-decode -f /path/to/file.braw
# Output example: -f rawvideo -pixel_format rgba -s 3840x2160 -r 23.976028 -i pipe:0

# Full conversion command (note: BRAW file for audio FIRST, then pipe parameters)
./braw-decode -t 8 /path/to/file.braw | ffmpeg -y \
  -i /path/to/file.braw \
  -f rawvideo -pixel_format rgba -s 3840x2160 -r 23.976028 -i pipe:0 \
  -map 1:v:0 -map 0:a:0 \
  -c:v libx264 -preset medium -crf 18 \
  -c:a aac -b:a 192k \
  -pix_fmt yuv420p \
  /path/to/output.mp4
```

**Command structure explained**:
- Input #0: The BRAW file (used for audio extraction)
- Input #1: The raw video pipe from braw-decode
- `-map 1:v:0`: Map video from input 1 (the decoded raw video)
- `-map 0:a:0`: Map audio from input 0 (the original BRAW file)

## Batch Conversion Script

Create a script named `convert_braw.sh`:

```bash
#!/bin/bash
set -e

# Configuration - UPDATE THESE PATHS
INPUT_DIR="/Volumes/stubsocho/mills_sbm/sbm_bill/Footage/4.6K"
BRAW_DECODE_DIR="/Volumes/stubsdosdos/git/braw-decode-macOS"
BRAW_DECODE="$BRAW_DECODE_DIR/../braw-decode"

# Must run from braw-decode directory for Libraries path
cd "$BRAW_DECODE_DIR"

# Verify braw-decode exists
if [[ ! -x "$BRAW_DECODE" ]]; then
    echo "Error: braw-decode not found at $BRAW_DECODE"
    exit 1
fi

# Process each BRAW file
for braw in "$INPUT_DIR"/*.braw; do
    filename=$(basename "$braw" .braw)
    output="$INPUT_DIR/${filename}.mp4"

    # Skip if already converted
    if [[ -f "$output" ]]; then
        echo "Skipping (exists): $filename"
        continue
    fi

    echo "Converting: $filename"
    echo "  Source: $braw"
    echo "  Output: $output"

    # Get FFmpeg parameters from the file (resolution, framerate)
    FF_PARAMS=$("$BRAW_DECODE" -f "$braw" 2>/dev/null)
    echo "  Params: $FF_PARAMS"

    # Decode and encode
    "$BRAW_DECODE" -t 8 "$braw" 2>/dev/null | ffmpeg -y \
      -i "$braw" \
      $FF_PARAMS \
      -map 1:v:0 -map 0:a:0 \
      -c:v libx264 -preset medium -crf 18 \
      -c:a aac -b:a 192k \
      -pix_fmt yuv420p \
      "$output" 2>&1 | tail -1

    echo "Done: $filename"
    echo "---"
done

echo "All conversions complete!"
```

Make it executable:

```bash
chmod +x convert_braw.sh
```

## FFmpeg Settings Explained

| Setting | Value | Description |
|---------|-------|-------------|
| `-c:v libx264` | H.264 codec | Widely compatible video codec |
| `-preset medium` | Encoding speed | Balance of speed and compression |
| `-crf 18` | Quality factor | Lower = higher quality (18 is high quality) |
| `-vf "scale=3840:2160:flags=lanczos"` | Resolution | Scale to 4K UHD with high-quality algorithm |
| `-c:a aac -b:a 192k` | Audio codec | AAC at 192kbps |
| `-pix_fmt yuv420p` | Pixel format | Ensures compatibility with most players |

### Quality Options

- **CRF 18**: High quality, larger files (recommended for archival)
- **CRF 20-23**: Good quality, smaller files (recommended for general use)
- **CRF 28+**: Lower quality, much smaller files

### Preset Options (speed vs compression)

- `ultrafast`: Fastest encoding, largest files
- `fast`: Good balance for quick jobs
- `medium`: Default, balanced
- `slow`: Better compression, slower encoding
- `veryslow`: Best compression, slowest encoding

## Verification

After conversion, verify the output:

```bash
# Check file exists and size
ls -lh /path/to/output.mp4

# Verify video properties
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,codec_name,duration \
  -of csv=p=0 /path/to/output.mp4

# Expected output format: h264,3840,2160,<duration>
```

## Troubleshooting

### Resolution/Framerate Issues

The batch script automatically detects resolution and framerate from each file using `braw-decode -f`. If you need to check manually:

```bash
# Get file info
./braw-decode -n /path/to/file.braw

# Get FFmpeg parameters
./braw-decode -f /path/to/file.braw
```

Example output:
```
Resolution: 3840x2160
Framerate: 23.976
Frame Count: 64
```

### Library Path Issues

If braw-decode crashes, it may not be finding the SDK libraries. Either:

1. Run from the directory containing the `Libraries` folder, or
2. Copy SDK libraries to `/usr/local/lib/brawsdk/` and update the path in `braw.h`

### Large Files

Very large BRAW files (100GB+) may require:
- Significant processing time
- Adequate free disk space for temporary data
- Consider using `-preset fast` for quicker (but larger) output

## Rails Integration

The Cuttymark app includes a `BrawDecoder` service and rake task for batch conversion.

### Environment Variables

The service automatically looks for `braw-decode` in these locations (in order):
1. `BRAW_DECODE_PATH` environment variable
2. `~/git/braw-decode`
3. `/Volumes/stubsdosdos/git/braw-decode`
4. System PATH

And for the Libraries directory:
1. `BRAW_DECODE_DIR` environment variable
2. `~/git/braw-decode-macOS`
3. `/Volumes/stubsdosdos/git/braw-decode-macOS`
4. Directory containing the braw-decode executable

Optionally set these in your shell or `.env` file to override:

```bash
BRAW_DECODE_PATH=~/git/braw-decode
BRAW_DECODE_DIR=~/git/braw-decode-macOS
```

### Rake Task Usage

```bash
# Dry run - list files without converting
rake cm:convert_braw[/path/to/folder,true]

# Convert all unconverted BRAW files in folder (auto encoder selection)
rake cm:convert_braw[/path/to/folder]

# Recursive search with dry run
rake cm:convert_braw[/path/to/folder,true,true]

# Recursive conversion
rake cm:convert_braw[/path/to/folder,false,true]

# Force hardware encoding
rake cm:convert_braw[/path/to/folder,false,false,hardware]

# Force software encoding (CPU)
rake cm:convert_braw[/path/to/folder,false,false,software]

# Use specific encoder
rake cm:convert_braw[/path/to/folder,false,false,h264_videotoolbox]
rake cm:convert_braw[/path/to/folder,false,false,hevc_videotoolbox]

# Recursive with hardware encoding
rake cm:convert_braw_recursive[/path/to/folder,false,hardware]
```

The task automatically:
- Detects FFmpeg version (requires 8.0+)
- Detects and uses hardware encoders when available
- Skips files that already have a corresponding .mp4
- Reports progress, encoder used, and success/failure counts
- Shows file sizes and conversion duration

### Using the Service Directly

```ruby
decoder = VideoProcessing::BrawDecoder.new

# Check availability
decoder.available?  # => true/false

# Check FFmpeg version (raises error if below 8.0)
decoder.check_ffmpeg_version!
decoder.ffmpeg_version  # => "8.0.1"

# Check available hardware encoders
decoder.available_hw_encoders
# => ["h264_videotoolbox", "hevc_videotoolbox", ...]

# Get encoder info
decoder.encoder_info(encoder: :auto)
# => "h264_videotoolbox (hardware)"

# Get file info
info = decoder.info("/path/to/file.braw")
# => #<FileInfo width=3840 height=2160 framerate=23.976 frame_count=1234 duration=51.5>

# Convert a file (auto-selects best encoder)
result = decoder.convert("/path/to/file.braw")
result.success?         # => true
result.output_path      # => "/path/to/file.mp4"
result.duration_seconds # => 12.3
result.encoder          # => "h264_videotoolbox"

# Find unconverted files
decoder.find_unconverted("/path/to/folder")
# => ["/path/to/folder/A001.braw", "/path/to/folder/A002.braw"]

# With options (software encoder)
decoder.convert(
  "/path/to/file.braw",
  output_path: "/custom/output.mp4",
  threads: 8,
  crf: 18,
  preset: "medium",
  audio_bitrate: "192k",
  encoder: :software  # Force CPU encoding
)

# With options (hardware encoder)
decoder.convert(
  "/path/to/file.braw",
  encoder: :hardware,  # Force hardware encoding
  quality: 65          # Quality for hardware encoder (1-100, lower=better)
)

# Use specific encoder
decoder.convert(
  "/path/to/file.braw",
  encoder: "hevc_videotoolbox"  # HEVC instead of H.264
)
```

## Performance

### Hardware-Accelerated Encoding

The Rails `BrawDecoder` service supports hardware-accelerated video encoding, which can significantly reduce encoding time and CPU usage.

#### Supported Hardware Encoders

| Platform | Encoder | Description |
|----------|---------|-------------|
| macOS (Apple Silicon/Intel) | `h264_videotoolbox` | VideoToolbox H.264 (default on macOS) |
| macOS (Apple Silicon/Intel) | `hevc_videotoolbox` | VideoToolbox HEVC/H.265 |
| Linux (NVIDIA GPU) | `h264_nvenc` | NVIDIA NVENC H.264 |
| Linux (NVIDIA GPU) | `hevc_nvenc` | NVIDIA NVENC HEVC |
| Linux (Intel/AMD) | `h264_vaapi` | VA-API H.264 |

#### Automatic Detection

The service automatically detects available hardware encoders and uses the best one for your platform. On M1/M2/M3 Macs, this means using VideoToolbox for GPU-accelerated encoding.

#### Performance Comparison (Apple M1 Max, 4K 24fps)

| Encoder | Time | CPU Usage | Notes |
|---------|------|-----------|-------|
| `libx264` (software) | ~45s | 100% | Default CPU encoder |
| `h264_videotoolbox` (hardware) | ~12s | <30% | GPU handles encoding |

Hardware encoding is typically 3-5x faster with much lower CPU usage.

#### Encoder Selection Options

When using the rake task or Ruby API, you can control encoder selection:

- `auto` (default): Automatically select the best available encoder
- `hardware` or `hw`: Force hardware encoding (falls back to software if unavailable)
- `software`, `sw`, or `cpu`: Force software encoding (libx264)
- Specific encoder name: e.g., `h264_videotoolbox`, `hevc_videotoolbox`

### CPU vs GPU Decoding

The **Blackmagic RAW SDK** supports GPU acceleration via:
- **Metal** (macOS)
- **CUDA** (NVIDIA)
- **OpenCL** (cross-platform)

However, **braw-decode is CPU-only**. It uses multi-threaded CPU decoding with the `-t` flag. This is still reasonably fast due to SDK optimizations for AVX, AVX2, and SSE4.1.

Note: While braw-decode uses CPU for decoding, the FFmpeg encoding step can use hardware acceleration (VideoToolbox, NVENC, etc.), which is where most of the processing time is spent.

For fully GPU-accelerated conversion (both decode and encode), use DaVinci Resolve instead.

### braw-decode CLI Options

```
-n, --info           Print clip details (resolution, framerate, frame count)
-f, --ff-format      Print FFmpeg input arguments
-t, --threads N      Number of CPU threads (default: 1, recommended: 8)
-c, --color-format   Output format: rgba, bgra, 16il, 16pl, f32s, f32p, f32a
-i, --in N           Start frame index
-o, --out N          End frame index
-s, --scale N        Scale factor: 1, 2, 4, or 8 (8-bit formats only)
-v, --verbose        Print more info to stderr
```

### Recommended Settings

| Use Case | CRF | Preset | Notes |
|----------|-----|--------|-------|
| Archival | 18 | medium | High quality, larger files |
| Editing proxy | 23 | fast | Good quality, faster encode |
| Quick preview | 28 | ultrafast | Lower quality, very fast |

## Alternative: DaVinci Resolve

If the command-line approach proves difficult, or you need GPU acceleration, DaVinci Resolve (free version) can convert BRAW files:

1. Download from https://www.blackmagicdesign.com/products/davinciresolve
2. Create a new project and import BRAW files
3. Go to the Deliver page
4. Set format to MP4, codec to H.264, resolution to 3840x2160
5. Add clips to render queue and start render

DaVinci Resolve uses full GPU acceleration for BRAW decoding and is significantly faster than braw-decode for large files.

## References

- [braw-decode-macOS](https://github.com/meisa233/braw-decode-macOS) - macOS fork of braw-decode
- [Blackmagic RAW SDK](https://www.blackmagicdesign.com/developer/products/braw) - Official SDK
- [Blackmagic RAW SDK Developer Manual](https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicRAW-SDK.pdf) - Full API documentation
- [braw-decode (original)](https://github.com/AkBKukU/braw-decode) - Original Linux project
- [FFmpeg Documentation](https://ffmpeg.org/documentation.html)
