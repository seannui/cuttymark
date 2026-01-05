require "open3"

module VideoProcessing
  class FfmpegClient
    class Error < StandardError; end
    class FileNotFoundError < Error; end
    class ConversionError < Error; end

    SUPPORTED_AUDIO_FORMATS = %w[wav mp3 m4a aac].freeze

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
  end
end
