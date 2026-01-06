require "open3"

module VideoProcessing
  class FfmpegClient
    class Error < StandardError; end
    class FileNotFoundError < Error; end
    class ConversionError < Error; end

    SUPPORTED_AUDIO_FORMATS = %w[wav mp3 m4a aac].freeze

    # Maximum chunk duration in seconds (10 minutes is safe for GPU memory)
    MAX_CHUNK_DURATION = 600

    def initialize
      @ffmpeg_path = find_executable("ffmpeg")
      @ffprobe_path = find_executable("ffprobe")
    end

    def extract_audio(video_path, output_path: nil, format: "wav", sample_rate: 16000, channels: 1)
      raise FileNotFoundError, "Video file not found: #{video_path}" unless File.exist?(video_path)

      output_path ||= default_audio_path(video_path, format)
      FileUtils.mkdir_p(File.dirname(output_path))

      cmd = [
        @ffmpeg_path,
        "-y",                           # Overwrite output
        "-i", video_path,               # Input file
        "-vn",                          # No video
        "-acodec", format == "wav" ? "pcm_s16le" : "aac",
        "-ar", sample_rate.to_s,        # Sample rate (16kHz for Whisper)
        "-ac", channels.to_s,           # Mono
        output_path
      ]

      execute_command(cmd, "Audio extraction failed")
      output_path
    end

    def get_metadata(video_path)
      raise FileNotFoundError, "Video file not found: #{video_path}" unless File.exist?(video_path)

      cmd = [
        @ffprobe_path,
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        video_path
      ]

      output = execute_command(cmd, "Metadata extraction failed", capture: true)
      parse_metadata(JSON.parse(output), video_path)
    end

    def render_clip(source_path, output_path, start_time:, end_time:, codec: "copy")
      raise FileNotFoundError, "Source file not found: #{source_path}" unless File.exist?(source_path)

      FileUtils.mkdir_p(File.dirname(output_path))
      duration = end_time - start_time

      cmd = [
        @ffmpeg_path,
        "-y",
        "-ss", start_time.to_s,         # Seek before input (faster)
        "-i", source_path,
        "-t", duration.to_s,            # Duration
        "-c", codec,                    # Copy streams (fast) or re-encode
        "-avoid_negative_ts", "make_zero",
        output_path
      ]

      execute_command(cmd, "Clip rendering failed")
      output_path
    end

    def render_clip_with_reencode(source_path, output_path, start_time:, end_time:, video_codec: "libx264", audio_codec: "aac", crf: 18)
      raise FileNotFoundError, "Source file not found: #{source_path}" unless File.exist?(source_path)

      FileUtils.mkdir_p(File.dirname(output_path))
      duration = end_time - start_time

      cmd = [
        @ffmpeg_path,
        "-y",
        "-ss", start_time.to_s,
        "-i", source_path,
        "-t", duration.to_s,
        "-c:v", video_codec,
        "-crf", crf.to_s,
        "-preset", "fast",
        "-c:a", audio_codec,
        "-b:a", "192k",
        output_path
      ]

      execute_command(cmd, "Clip rendering failed")
      output_path
    end

    def available?
      File.executable?(@ffmpeg_path) && File.executable?(@ffprobe_path)
    end

    # Get audio duration in seconds
    def get_audio_duration(audio_path)
      raise FileNotFoundError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      cmd = [
        @ffprobe_path,
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        audio_path
      ]

      output = execute_command(cmd, "Duration extraction failed", capture: true)
      output.strip.to_f
    end

    # Get mean volume in dB (used to detect low-volume audio that may cause Whisper hallucination)
    def get_mean_volume(audio_path)
      raise FileNotFoundError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      cmd = [
        @ffmpeg_path,
        "-i", audio_path,
        "-af", "volumedetect",
        "-f", "null",
        "-"
      ]

      # volumedetect outputs to stderr
      _output, error, status = Open3.capture3(*cmd)
      unless status.success?
        Rails.logger.warn("Volume detection failed, assuming normal volume")
        return 0.0
      end

      # Parse mean_volume from output like: [Parsed_volumedetect_0 ...] mean_volume: -36.3 dB
      if error =~ /mean_volume:\s*([-\d.]+)\s*dB/
        ::Regexp.last_match(1).to_f
      else
        Rails.logger.warn("Could not parse mean volume from ffmpeg output")
        0.0
      end
    end

    # Check if audio needs chunking based on duration
    def needs_chunking?(audio_path, max_duration: MAX_CHUNK_DURATION)
      get_audio_duration(audio_path) > max_duration
    end

    # Split audio file into chunks with overlap for better transcription continuity
    def split_audio_into_chunks(audio_path, output_dir:, chunk_duration: MAX_CHUNK_DURATION, overlap: 2)
      raise FileNotFoundError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      FileUtils.mkdir_p(output_dir)
      total_duration = get_audio_duration(audio_path)
      chunks = []
      chunk_index = 0
      current_start = 0.0

      while current_start < total_duration
        chunk_path = File.join(output_dir, "chunk_#{chunk_index.to_s.rjust(4, '0')}.wav")
        actual_duration = [chunk_duration, total_duration - current_start].min

        cmd = [
          @ffmpeg_path,
          "-y",
          "-ss", current_start.to_s,
          "-i", audio_path,
          "-t", actual_duration.to_s,
          "-acodec", "pcm_s16le",
          "-ar", "16000",
          "-ac", "1",
          chunk_path
        ]

        execute_command(cmd, "Chunk extraction failed for chunk #{chunk_index}")

        chunks << AudioChunk.new(
          path: chunk_path,
          index: chunk_index,
          start_time: current_start,
          duration: actual_duration
        )

        chunk_index += 1
        # Move forward by chunk_duration minus overlap (overlap helps with word boundaries)
        current_start += (chunk_duration - overlap)
      end

      Rails.logger.info("Split audio into #{chunks.size} chunks")
      chunks
    end

    # Validate audio file is suitable for Whisper processing
    def validate_audio(audio_path)
      raise FileNotFoundError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      errors = []
      metadata = get_audio_metadata(audio_path)

      # Check sample rate (Whisper expects 16kHz)
      if metadata[:sample_rate] && metadata[:sample_rate] != 16000
        errors << "Sample rate is #{metadata[:sample_rate]}Hz, expected 16000Hz"
      end

      # Check channels (Whisper expects mono)
      if metadata[:channels] && metadata[:channels] != 1
        errors << "Audio has #{metadata[:channels]} channels, expected mono (1)"
      end

      # Check codec
      if metadata[:codec_name] && metadata[:codec_name] != "pcm_s16le"
        errors << "Codec is #{metadata[:codec_name]}, expected pcm_s16le"
      end

      # Check duration is not zero
      if metadata[:duration] && metadata[:duration] <= 0
        errors << "Audio duration is zero or negative"
      end

      ValidationResult.new(
        valid: errors.empty?,
        errors: errors,
        metadata: metadata
      )
    end

    # Re-encode audio to Whisper-compatible format with optional normalization
    def normalize_audio(input_path, output_path: nil, normalize_volume: true)
      raise FileNotFoundError, "Audio file not found: #{input_path}" unless File.exist?(input_path)

      output_path ||= input_path.sub(/\.[^.]+$/, "_normalized.wav")
      FileUtils.mkdir_p(File.dirname(output_path))

      # Build filter chain
      filters = ["aresample=async=1000"]
      filters << "loudnorm=I=-16:TP=-1.5:LRA=11" if normalize_volume
      filters << "lowpass=f=8000"  # Anti-aliasing for 16kHz

      cmd = [
        @ffmpeg_path,
        "-y",
        "-i", input_path,
        "-ar", "16000",
        "-ac", "1",
        "-acodec", "pcm_s16le",
        "-af", filters.join(","),
        output_path
      ]

      execute_command(cmd, "Audio normalization failed")
      output_path
    end

    def get_audio_metadata(audio_path)
      cmd = [
        @ffprobe_path,
        "-v", "quiet",
        "-print_format", "json",
        "-show_streams",
        "-select_streams", "a:0",
        audio_path
      ]

      output = execute_command(cmd, "Audio metadata extraction failed", capture: true)
      data = JSON.parse(output)
      stream = data["streams"]&.first || {}

      {
        codec_name: stream["codec_name"],
        sample_rate: stream["sample_rate"]&.to_i,
        channels: stream["channels"],
        duration: stream["duration"]&.to_f,
        bit_rate: stream["bit_rate"]&.to_i
      }
    end

    def version
      output = `#{@ffmpeg_path} -version 2>&1`
      output.lines.first&.strip
    rescue StandardError
      nil
    end

    private

    def find_executable(name)
      # Check common paths
      paths = [
        "/usr/local/bin/#{name}",
        "/opt/homebrew/bin/#{name}",
        "/usr/bin/#{name}",
        `which #{name} 2>/dev/null`.strip
      ]

      paths.find { |p| File.executable?(p) } || name
    end

    def default_audio_path(video_path, format)
      base = File.basename(video_path, ".*")
      Rails.root.join("storage", "audio", "#{base}_#{Time.current.to_i}.#{format}").to_s
    end

    def execute_command(cmd, error_message, capture: false)
      Rails.logger.debug { "FFmpeg command: #{cmd.join(' ')}" }

      if capture
        output, status = Open3.capture2(*cmd)
        raise ConversionError, "#{error_message}: #{output}" unless status.success?
        output
      else
        output, error, status = Open3.capture3(*cmd)
        unless status.success?
          Rails.logger.error("FFmpeg error: #{error}")
          raise ConversionError, "#{error_message}: #{error}"
        end
        output
      end
    end

    def parse_metadata(data, video_path)
      format = data["format"] || {}
      video_stream = data["streams"]&.find { |s| s["codec_type"] == "video" }
      audio_stream = data["streams"]&.find { |s| s["codec_type"] == "audio" }

      Metadata.new(
        duration: format["duration"]&.to_f,
        file_size: format["size"]&.to_i || File.size(video_path),
        format: File.extname(video_path).delete(".").downcase,
        bit_rate: format["bit_rate"]&.to_i,
        video_codec: video_stream&.dig("codec_name"),
        video_width: video_stream&.dig("width"),
        video_height: video_stream&.dig("height"),
        frame_rate: parse_frame_rate(video_stream&.dig("r_frame_rate")),
        audio_codec: audio_stream&.dig("codec_name"),
        audio_sample_rate: audio_stream&.dig("sample_rate")&.to_i,
        audio_channels: audio_stream&.dig("channels")
      )
    end

    def parse_frame_rate(rate_string)
      return nil unless rate_string

      num, den = rate_string.split("/").map(&:to_f)
      den.zero? ? nil : (num / den).round(2)
    end

    Metadata = Struct.new(
      :duration, :file_size, :format, :bit_rate,
      :video_codec, :video_width, :video_height, :frame_rate,
      :audio_codec, :audio_sample_rate, :audio_channels,
      keyword_init: true
    )

    AudioChunk = Struct.new(
      :path, :index, :start_time, :duration,
      keyword_init: true
    )

    ValidationResult = Struct.new(
      :valid, :errors, :metadata,
      keyword_init: true
    ) do
      def valid?
        valid
      end
    end
  end
end
