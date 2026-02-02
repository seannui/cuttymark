require "open3"

module VideoProcessing
  class BrawDecoder
    class Error < StandardError; end
    class FileNotFoundError < Error; end
    class ConversionError < Error; end
    class ExecutableNotFoundError < Error; end

    DEFAULT_THREADS = 8
    DEFAULT_CRF = 18
    DEFAULT_PRESET = "medium"
    DEFAULT_AUDIO_BITRATE = "192k"

    def initialize
      @braw_decode_path = find_braw_decode
      @braw_decode_dir = find_braw_decode_dir
      @ffmpeg_path = find_executable("ffmpeg")
    end

    def available?
      File.executable?(@braw_decode_path) && File.executable?(@ffmpeg_path)
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

      execute_in_braw_dir("#{@braw_decode_path} -f #{Shellwords.escape(braw_path)}").strip
    end

    # Convert a BRAW file to MP4
    # Returns ConversionResult struct
    def convert(braw_path, output_path: nil, threads: DEFAULT_THREADS,
                crf: DEFAULT_CRF, preset: DEFAULT_PRESET, audio_bitrate: DEFAULT_AUDIO_BITRATE)
      raise FileNotFoundError, "BRAW file not found: #{braw_path}" unless File.exist?(braw_path)

      output_path ||= braw_path.sub(/\.braw$/i, ".mp4")
      FileUtils.mkdir_p(File.dirname(output_path))

      start_time = Time.current

      begin
        ff_params = ffmpeg_params(braw_path)

        # Build the conversion command
        # Must run from braw-decode directory where Libraries folder is located
        cmd = build_conversion_command(
          braw_path: braw_path,
          output_path: output_path,
          ff_params: ff_params,
          threads: threads,
          crf: crf,
          preset: preset,
          audio_bitrate: audio_bitrate
        )

        Rails.logger.info("Converting BRAW: #{braw_path}")
        Rails.logger.debug { "BRAW conversion command: #{cmd}" }

        # Execute from the braw-decode directory
        output, error, status = Open3.capture3(cmd, chdir: @braw_decode_dir)

        unless status.success?
          Rails.logger.error("BRAW conversion failed: #{error}")
          return ConversionResult.new(
            success: false,
            input_path: braw_path,
            output_path: output_path,
            duration_seconds: nil,
            error: error.strip
          )
        end

        elapsed = Time.current - start_time

        ConversionResult.new(
          success: true,
          input_path: braw_path,
          output_path: output_path,
          duration_seconds: elapsed.round(1),
          error: nil
        )
      rescue StandardError => e
        ConversionResult.new(
          success: false,
          input_path: braw_path,
          output_path: output_path,
          duration_seconds: nil,
          error: e.message
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

    def find_braw_decode
      paths = [
        ENV["BRAW_DECODE_PATH"],
        "/Volumes/stubsdosdos/git/braw-decode",
        File.expand_path("~/git/braw-decode"),
        `which braw-decode 2>/dev/null`.strip
      ].compact.reject(&:empty?)

      found = paths.find { |p| File.executable?(p) }
      raise ExecutableNotFoundError, "braw-decode not found. Set BRAW_DECODE_PATH or ensure it's in PATH." unless found

      found
    end

    def find_braw_decode_dir
      # The braw-decode executable must be run from the directory containing the Libraries folder
      # Typically this is braw-decode-macOS directory
      paths = [
        ENV["BRAW_DECODE_DIR"],
        "/Volumes/stubsdosdos/git/braw-decode-macOS",
        File.expand_path("~/git/braw-decode-macOS"),
        File.dirname(@braw_decode_path)
      ].compact.reject(&:empty?)

      found = paths.find { |p| Dir.exist?(p) && Dir.exist?(File.join(p, "Libraries")) }
      raise ExecutableNotFoundError, "braw-decode Libraries directory not found. Set BRAW_DECODE_DIR." unless found

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

    def build_conversion_command(braw_path:, output_path:, ff_params:, threads:, crf:, preset:, audio_bitrate:)
      escaped_input = Shellwords.escape(braw_path)
      escaped_output = Shellwords.escape(output_path)

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
        -c:v libx264 -preset #{preset} -crf #{crf}
        -c:a aac -b:a #{audio_bitrate}
        -pix_fmt yuv420p
        #{escaped_output}
      CMD
    end

    FileInfo = Struct.new(
      :width, :height, :framerate, :frame_count, :duration,
      keyword_init: true
    )

    ConversionResult = Struct.new(
      :success, :input_path, :output_path, :duration_seconds, :error,
      keyword_init: true
    ) do
      def success?
        success
      end
    end
  end
end
