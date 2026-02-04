require "open3"

module VideoProcessing
  class BrawDecoder
    class Error < StandardError; end
    class FileNotFoundError < Error; end
    class ConversionError < Error; end
    class ExecutableNotFoundError < Error; end
    class FFmpegVersionError < Error; end

    MINIMUM_FFMPEG_VERSION = "8.0"
    DEFAULT_THREADS = 8
    DEFAULT_CRF = 18
    DEFAULT_PRESET = "medium"
    DEFAULT_AUDIO_BITRATE = "192k"
    DEFAULT_ENCODER = :auto
    DEFAULT_HW_QUALITY = 65 # Roughly equivalent to CRF 18
    MAX_OUTPUT_WIDTH = 3840 # Scale down to 4K if source is larger

    # Encoder configurations by platform
    HARDWARE_ENCODERS = {
      macos: {
        h264_videotoolbox: { codec: "h264_videotoolbox", profile: "high", priority: 1 },
        hevc_videotoolbox: { codec: "hevc_videotoolbox", profile: "main", priority: 2 }
      },
      linux: {
        h264_nvenc: { codec: "h264_nvenc", profile: "high", priority: 1 },
        hevc_nvenc: { codec: "hevc_nvenc", profile: "main", priority: 2 },
        h264_vaapi: { codec: "h264_vaapi", profile: nil, priority: 3 }
      }
    }.freeze

    SOFTWARE_ENCODER = { codec: "libx264", profile: nil }.freeze

    def initialize
      @braw_decode_path = find_braw_decode
      @braw_decode_dir = find_braw_decode_dir
      @ffmpeg_path = find_executable("ffmpeg")
      @platform = detect_platform
      @available_encoders = nil # Lazy-loaded
    end

    def available?
      File.executable?(@braw_decode_path) && File.executable?(@ffmpeg_path)
    end

    # Returns the FFmpeg version as a string (e.g., "8.0.1")
    def ffmpeg_version
      @ffmpeg_version ||= begin
        output, _error, _status = Open3.capture3("#{@ffmpeg_path} -version")
        # Parse version from line like: "ffmpeg version 8.0.1 Copyright ..."
        if output =~ /ffmpeg version (\d+\.\d+(?:\.\d+)?)/
          ::Regexp.last_match(1)
        end
      end
    end

    # Raises FFmpegVersionError if FFmpeg version is below minimum
    def check_ffmpeg_version!
      current = ffmpeg_version
      raise FFmpegVersionError, "Could not determine FFmpeg version" unless current

      if Gem::Version.new(current) < Gem::Version.new(MINIMUM_FFMPEG_VERSION)
        raise FFmpegVersionError,
              "FFmpeg #{MINIMUM_FFMPEG_VERSION}+ required (found #{current}). " \
              "Run: brew upgrade ffmpeg"
      end
      true
    end

    # Detect the current platform
    def detect_platform
      case RUBY_PLATFORM
      when /darwin/
        :macos
      when /linux/
        :linux
      when /mswin|mingw/
        :windows
      else
        :unknown
      end
    end

    # Returns array of available hardware encoder names
    def available_hw_encoders
      @available_encoders ||= begin
        output, _error, _status = Open3.capture3("#{@ffmpeg_path} -encoders")
        encoders = []

        # Parse encoder list, looking for video encoders (V.....)
        output.each_line do |line|
          # Format: " V..... h264_videotoolbox   VideoToolbox H.264 Encoder"
          if line =~ /^\s*V[\.\w]+\s+(\w+)/
            encoders << ::Regexp.last_match(1)
          end
        end

        encoders
      end
    end

    # Returns the best encoder configuration for the current platform
    # Options:
    #   encoder: :auto (default), :hardware, :software, or specific encoder name
    def best_encoder_config(encoder: DEFAULT_ENCODER)
      case encoder
      when :software
        SOFTWARE_ENCODER.merge(type: :software)
      when :hardware
        find_hardware_encoder || SOFTWARE_ENCODER.merge(type: :software)
      when :auto
        find_hardware_encoder || SOFTWARE_ENCODER.merge(type: :software)
      when String, Symbol
        # Specific encoder requested
        encoder_name = encoder.to_s
        if available_hw_encoders.include?(encoder_name)
          platform_encoders = HARDWARE_ENCODERS[@platform] || {}
          config = platform_encoders[encoder_name.to_sym]
          if config
            config.merge(type: :hardware)
          else
            { codec: encoder_name, profile: nil, type: :hardware }
          end
        elsif encoder_name == "libx264"
          SOFTWARE_ENCODER.merge(type: :software)
        else
          Rails.logger.warn("Encoder '#{encoder_name}' not available, falling back to software")
          SOFTWARE_ENCODER.merge(type: :software)
        end
      else
        SOFTWARE_ENCODER.merge(type: :software)
      end
    end

    # Returns encoder info string for display
    def encoder_info(encoder: DEFAULT_ENCODER)
      config = best_encoder_config(encoder: encoder)
      if config[:type] == :hardware
        "#{config[:codec]} (hardware)"
      else
        "#{config[:codec]} (software/CPU)"
      end
    end

    # Get information about a BRAW file
    # Returns FileInfo struct with width, height, framerate, frame_count, duration
    def info(braw_path)
      raise FileNotFoundError, "BRAW file not found: #{braw_path}" unless File.exist?(braw_path)

      output = execute_in_braw_dir("#{@braw_decode_path} -n #{Shellwords.escape(braw_path)}")

      # Parse output like:
      # Resolution: 3840x2160
      # Framerate: 23.976
      # Frame Count: 64
      width = height = nil
      if output =~ /Resolution:\s*(\d+)x(\d+)/
        width = ::Regexp.last_match(1).to_i
        height = ::Regexp.last_match(2).to_i
      end

      framerate = output =~ /Framerate:\s*([\d.]+)/ ? ::Regexp.last_match(1).to_f : nil
      frame_count = output =~ /Frame Count:\s*(\d+)/ ? ::Regexp.last_match(1).to_i : nil

      duration = (frame_count && framerate && framerate > 0) ? frame_count / framerate : nil

      FileInfo.new(
        width: width,
        height: height,
        framerate: framerate,
        frame_count: frame_count,
        duration: duration
      )
    end

    # Get FFmpeg input parameters for a BRAW file
    # Returns string like: -f rawvideo -pixel_format rgba -s 3840x2160 -r 23.976028 -i pipe:0
    def ffmpeg_params(braw_path)
      raise FileNotFoundError, "BRAW file not found: #{braw_path}" unless File.exist?(braw_path)

      # Use absolute path since command runs from braw-decode directory
      absolute_path = File.absolute_path(braw_path)
      execute_in_braw_dir("#{@braw_decode_path} -f #{Shellwords.escape(absolute_path)}").strip
    end

    # Convert a BRAW file to MP4
    # Returns ConversionResult struct
    #
    # Options:
    #   output_path: custom output path (default: same as input with .mp4 extension)
    #   threads: number of braw-decode threads (default: 8)
    #   crf: quality for software encoder (default: 18, lower = better)
    #   preset: speed preset for software encoder (default: "medium")
    #   audio_bitrate: audio bitrate (default: "192k")
    #   encoder: :auto, :hardware, :software, or specific encoder name (default: :auto)
    #   quality: quality for hardware encoder (default: 65, 1-100, lower = better)
    def convert(braw_path, output_path: nil, threads: DEFAULT_THREADS,
                crf: DEFAULT_CRF, preset: DEFAULT_PRESET, audio_bitrate: DEFAULT_AUDIO_BITRATE,
                encoder: DEFAULT_ENCODER, quality: DEFAULT_HW_QUALITY)
      raise FileNotFoundError, "BRAW file not found: #{braw_path}" unless File.exist?(braw_path)

      # Use absolute paths since commands run from braw-decode directory
      braw_path = File.absolute_path(braw_path)
      output_path = File.absolute_path(output_path || braw_path.sub(/\.braw$/i, ".mp4"))
      FileUtils.mkdir_p(File.dirname(output_path))

      start_time = Time.current

      begin
        ff_params = ffmpeg_params(braw_path)

        # Parse resolution from ff_params to check if we need to scale down
        # ff_params looks like: -f rawvideo -pixel_format rgba -s 6144x3456 -r 24 -i pipe:0
        video_width = ff_params =~ /-s\s+(\d+)x\d+/ ? ::Regexp.last_match(1).to_i : 0
        needs_scale = video_width > MAX_OUTPUT_WIDTH

        if needs_scale
          Rails.logger.info("Resolution #{video_width}px exceeds #{MAX_OUTPUT_WIDTH}px, will scale to 4K")
        end

        encoder_config = best_encoder_config(encoder: encoder)

        # Build the conversion command
        # Must run from braw-decode directory where Libraries folder is located
        cmd = build_conversion_command(
          braw_path: braw_path,
          output_path: output_path,
          ff_params: ff_params,
          threads: threads,
          crf: crf,
          preset: preset,
          audio_bitrate: audio_bitrate,
          encoder_config: encoder_config,
          quality: quality,
          scale_to_4k: needs_scale
        )

        scale_info = needs_scale ? ", scaling to 4K" : ""
        Rails.logger.info("Converting BRAW: #{braw_path} (encoder: #{encoder_config[:codec]}#{scale_info})")
        Rails.logger.debug { "BRAW conversion command: #{cmd}" }

        # Execute from the braw-decode directory
        output, error, status = Open3.capture3(cmd, chdir: @braw_decode_dir)

        unless status.success?
          Rails.logger.error("BRAW conversion failed: #{error}")
          # Clean up failed output file to avoid leaving invalid files
          cleanup_failed_output(output_path)
          return ConversionResult.new(
            success: false,
            input_path: braw_path,
            output_path: output_path,
            duration_seconds: nil,
            error: error.strip,
            encoder: encoder_config[:codec]
          )
        end

        elapsed = Time.current - start_time

        ConversionResult.new(
          success: true,
          input_path: braw_path,
          output_path: output_path,
          duration_seconds: elapsed.round(1),
          error: nil,
          encoder: encoder_config[:codec]
        )
      rescue StandardError => e
        # Clean up failed output file to avoid leaving invalid files
        cleanup_failed_output(output_path)
        ConversionResult.new(
          success: false,
          input_path: braw_path,
          output_path: output_path,
          duration_seconds: nil,
          error: e.message,
          encoder: nil
        )
      end
    end

    # Check if a BRAW file needs conversion (no corresponding MP4 exists)
    def needs_conversion?(braw_path)
      mp4_path = braw_path.sub(/\.braw$/i, ".mp4")
      !File.exist?(mp4_path)
    end

    # Find all BRAW files in a directory that don't have corresponding MP4 files
    def find_unconverted(directory, recursive: false)
      raise FileNotFoundError, "Directory not found: #{directory}" unless Dir.exist?(directory)

      pattern = recursive ? File.join(directory, "**", "*.braw") : File.join(directory, "*.braw")
      braw_files = Dir.glob(pattern, File::FNM_CASEFOLD)

      braw_files.select { |braw_path| needs_conversion?(braw_path) }.sort
    end

    # Find all BRAW files in a directory (regardless of conversion status)
    def find_all(directory, recursive: false)
      raise FileNotFoundError, "Directory not found: #{directory}" unless Dir.exist?(directory)

      pattern = recursive ? File.join(directory, "**", "*.braw") : File.join(directory, "*.braw")
      Dir.glob(pattern, File::FNM_CASEFOLD).sort
    end

    def version
      output = execute_in_braw_dir("#{@braw_decode_path} --help 2>&1 || true")
      # braw-decode may not have a version flag, just return path info
      "braw-decode at #{@braw_decode_path}"
    rescue StandardError
      nil
    end

    private

    # Remove invalid/incomplete output files after failed conversion
    def cleanup_failed_output(output_path)
      return unless output_path && File.exist?(output_path)

      # Only delete if file is empty or very small (likely incomplete)
      file_size = File.size(output_path)
      if file_size < 1024 # Less than 1KB is definitely invalid
        Rails.logger.info("Cleaning up failed output file: #{output_path} (#{file_size} bytes)")
        FileUtils.rm_f(output_path)
      end
    rescue StandardError => e
      Rails.logger.warn("Failed to clean up output file #{output_path}: #{e.message}")
    end

    def find_braw_decode
      # Priority order:
      # 1. Environment variable (allows override)
      # 2. Metal GPU version (faster)
      # 3. CPU version (fallback)
      # 4. System PATH
      paths = [
        ENV["BRAW_DECODE_PATH"],
        # Metal GPU version (preferred for performance)
        File.expand_path("~/git/braw-decode-metal/braw-decode-metal"),
        "/Volumes/stubsdosdos/git/braw-decode-metal/braw-decode-metal",
        # CPU version (fallback)
        File.expand_path("~/git/braw-decode-macOS/braw-decode"),
        "/Volumes/stubsdosdos/git/braw-decode-macOS/braw-decode",
        File.expand_path("~/git/braw-decode"),
        "/Volumes/stubsdosdos/git/braw-decode",
        `which braw-decode-metal 2>/dev/null`.strip,
        `which braw-decode 2>/dev/null`.strip
      ].compact.reject(&:empty?)

      found = paths.find { |p| File.executable?(p) }
      raise ExecutableNotFoundError, "braw-decode not found. Set BRAW_DECODE_PATH environment variable." unless found

      # Log which version we're using
      is_metal = found.include?("metal")
      Rails.logger.info("Using braw-decode: #{found} (#{is_metal ? 'Metal GPU' : 'CPU'})")

      found
    end

    def find_braw_decode_dir
      # The braw-decode executable must be run from the directory containing the Libraries folder
      # Priority order matches find_braw_decode
      paths = [
        ENV["BRAW_DECODE_DIR"],
        # Metal GPU version directory
        File.expand_path("~/git/braw-decode-metal"),
        "/Volumes/stubsdosdos/git/braw-decode-metal",
        # CPU version directory
        File.expand_path("~/git/braw-decode-macOS"),
        "/Volumes/stubsdosdos/git/braw-decode-macOS",
        File.dirname(@braw_decode_path)
      ].compact.reject(&:empty?)

      found = paths.find { |p| Dir.exist?(p) && Dir.exist?(File.join(p, "Libraries")) }
      raise ExecutableNotFoundError, "braw-decode Libraries directory not found. Set BRAW_DECODE_DIR environment variable." unless found

      found
    end

    def find_executable(name)
      paths = [
        "/usr/local/bin/#{name}",
        "/opt/homebrew/bin/#{name}",
        "/usr/bin/#{name}",
        `which #{name} 2>/dev/null`.strip
      ]

      paths.find { |p| File.executable?(p) } || name
    end

    def execute_in_braw_dir(cmd)
      output, error, status = Open3.capture3(cmd, chdir: @braw_decode_dir)
      raise ConversionError, "Command failed: #{error}" unless status.success?

      output
    end

    def build_conversion_command(braw_path:, output_path:, ff_params:, threads:, crf:, preset:,
                                   audio_bitrate:, encoder_config:, quality:, scale_to_4k: false)
      escaped_input = Shellwords.escape(braw_path)
      escaped_output = Shellwords.escape(output_path)

      # Build encoder-specific arguments
      video_codec_args = build_video_codec_args(
        encoder_config: encoder_config,
        crf: crf,
        preset: preset,
        quality: quality
      )

      # Scale filter for resolutions larger than 4K
      # Using lanczos for high quality downscaling, -2 ensures height is divisible by 2
      scale_filter = scale_to_4k ? "-vf scale=#{MAX_OUTPUT_WIDTH}:-2:flags=lanczos" : ""

      # The command structure:
      # 1. braw-decode pipes raw video to ffmpeg
      # 2. ffmpeg takes the original BRAW as first input (for audio)
      # 3. ffmpeg takes the piped raw video as second input
      # 4. Map video from input 1 (pipe), audio from input 0 (BRAW)
      <<~CMD.squish
        #{Shellwords.escape(@braw_decode_path)} -t #{threads} #{escaped_input} 2>/dev/null |
        #{Shellwords.escape(@ffmpeg_path)} -y
        -i #{escaped_input}
        #{ff_params}
        -map 1:v:0 -map 0:a:0
        #{scale_filter}
        #{video_codec_args}
        -c:a aac -b:a #{audio_bitrate}
        #{escaped_output}
      CMD
    end

    def build_video_codec_args(encoder_config:, crf:, preset:, quality:)
      codec = encoder_config[:codec]

      case codec
      when "h264_videotoolbox"
        # VideoToolbox H.264 encoder
        # -q:v: Quality (1-100, lower = better quality)
        # -profile:v high: H.264 High profile for better compatibility
        # -prio_speed true: Prioritize encoding speed
        # -allow_sw 1: Allow software fallback for resolutions exceeding HW limits (e.g., 6K)
        # Note: VideoToolbox handles pixel format conversion internally
        args = ["-c:v h264_videotoolbox"]
        args << "-allow_sw 1" # Fallback to software for large resolutions like 6K
        args << "-profile:v #{encoder_config[:profile]}" if encoder_config[:profile]
        args << "-q:v #{quality}"
        args << "-prio_speed true"
        args.join(" ")

      when "hevc_videotoolbox"
        # VideoToolbox HEVC encoder
        # HEVC supports larger resolutions in hardware than H.264
        # -allow_sw 1: Still allow software fallback for edge cases
        args = ["-c:v hevc_videotoolbox"]
        args << "-allow_sw 1" # Fallback to software for edge cases
        args << "-profile:v #{encoder_config[:profile]}" if encoder_config[:profile]
        args << "-q:v #{quality}"
        args << "-prio_speed true"
        args << "-tag:v hvc1" # Better compatibility with QuickTime
        args.join(" ")

      when "h264_nvenc"
        # NVIDIA NVENC H.264 encoder
        # -cq: Constant quality mode (0-51, similar to CRF)
        args = ["-c:v h264_nvenc"]
        args << "-profile:v #{encoder_config[:profile]}" if encoder_config[:profile]
        args << "-preset p4" # Balanced preset
        args << "-cq #{crf}" # Use CRF-like quality
        args << "-pix_fmt yuv420p"
        args.join(" ")

      when "hevc_nvenc"
        # NVIDIA NVENC HEVC encoder
        args = ["-c:v hevc_nvenc"]
        args << "-profile:v #{encoder_config[:profile]}" if encoder_config[:profile]
        args << "-preset p4"
        args << "-cq #{crf}"
        args << "-pix_fmt yuv420p"
        args.join(" ")

      when "h264_vaapi"
        # VA-API H.264 encoder (Intel/AMD on Linux)
        args = ["-c:v h264_vaapi"]
        args << "-qp #{crf}"
        args.join(" ")

      else
        # Software encoder (libx264)
        args = ["-c:v libx264"]
        args << "-preset #{preset}"
        args << "-crf #{crf}"
        args << "-pix_fmt yuv420p"
        args.join(" ")
      end
    end

    def find_hardware_encoder
      platform_encoders = HARDWARE_ENCODERS[@platform]
      return nil unless platform_encoders

      available = available_hw_encoders

      # Find the highest priority available encoder
      platform_encoders
        .select { |name, _config| available.include?(name.to_s) }
        .min_by { |_name, config| config[:priority] }
        &.then { |name, config| config.merge(name: name, type: :hardware) }
    end

    FileInfo = Struct.new(
      :width, :height, :framerate, :frame_count, :duration,
      keyword_init: true
    )

    ConversionResult = Struct.new(
      :success, :input_path, :output_path, :duration_seconds, :error, :encoder,
      keyword_init: true
    ) do
      def success?
        success
      end
    end
  end
end
