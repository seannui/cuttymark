require "open3"
require "fileutils"

module VideoProcessing
  class HlsService
    class Error < StandardError; end

    VARIANTS = [
      { name: "360p",  width: 640,  height: 360,  video_bitrate: "800k",   audio_bitrate: "96k",  bandwidth: 896_000 },
      { name: "720p",  width: 1280, height: 720,  video_bitrate: "2500k",  audio_bitrate: "128k", bandwidth: 2_628_000 },
      { name: "1080p", width: 1920, height: 1080, video_bitrate: "5000k",  audio_bitrate: "128k", bandwidth: 5_128_000 },
      { name: "2160p", width: 3840, height: 2160, video_bitrate: "15000k", audio_bitrate: "128k", bandwidth: 15_128_000 }
    ].freeze

    SEGMENT_DURATION = 6

    def initialize(video)
      @video = video
      @ffmpeg_path = find_ffmpeg
    end

    def generate!
      input_path = @video.playable_path
      raise Error, "Video file not found: #{input_path}" unless File.exist?(input_path)

      variants = applicable_variants
      raise Error, "No applicable variants for source resolution #{source_width}x#{source_height}" if variants.empty?

      # Create output directory
      FileUtils.mkdir_p(@video.hls_path)

      Rails.logger.info("[HlsService] Generating HLS for video #{@video.id} (#{variants.size} variants)")

      variants.each do |variant|
        encode_variant(variant)
      end

      write_master_playlist(variants)

      Rails.logger.info("[HlsService] HLS generation complete for video #{@video.id}")
    end

    def applicable_variants
      VARIANTS.select { |v| v[:height] <= source_height && v[:width] <= source_width }
    end

    private

    def encode_variant(variant)
      variant_dir = @video.hls_path.join(variant[:name])
      FileUtils.mkdir_p(variant_dir)

      segment_pattern = variant_dir.join("segment_%04d.ts").to_s
      playlist_path = variant_dir.join("stream.m3u8").to_s
      input_path = @video.playable_path

      cmd = build_ffmpeg_command(input_path, variant, segment_pattern, playlist_path)

      Rails.logger.info("[HlsService] Encoding #{variant[:name]} for video #{@video.id}")

      stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        # If hardware encoding failed, retry with software
        if cmd.include?("h264_videotoolbox")
          Rails.logger.warn("[HlsService] Hardware encoding failed for #{variant[:name]}, falling back to software")
          cmd = build_ffmpeg_command(input_path, variant, segment_pattern, playlist_path, software: true)
          stdout, stderr, status = Open3.capture3(*cmd)
        end

        unless status.success?
          raise Error, "FFmpeg failed for #{variant[:name]}: #{stderr.last(500)}"
        end
      end

      Rails.logger.info("[HlsService] Completed #{variant[:name]} for video #{@video.id}")
    end

    def build_ffmpeg_command(input_path, variant, segment_pattern, playlist_path, software: false)
      cmd = [
        @ffmpeg_path, "-y",
        "-i", input_path.to_s,
        "-vf", "scale=#{variant[:width]}:-2"
      ]

      if !software && hardware_encoder_available?
        cmd += [
          "-c:v", "h264_videotoolbox",
          "-b:v", variant[:video_bitrate],
          "-allow_sw", "1"
        ]
      else
        cmd += [
          "-c:v", "libx264",
          "-b:v", variant[:video_bitrate],
          "-preset", "medium",
          "-profile:v", "high"
        ]
      end

      cmd += [
        "-c:a", "aac",
        "-b:a", variant[:audio_bitrate],
        "-ac", "2",
        "-f", "hls",
        "-hls_time", SEGMENT_DURATION.to_s,
        "-hls_playlist_type", "vod",
        "-hls_segment_filename", segment_pattern,
        playlist_path
      ]

      cmd
    end

    def write_master_playlist(variants)
      master_path = @video.hls_master_playlist

      lines = ["#EXTM3U"]
      variants.each do |variant|
        lines << "#EXT-X-STREAM-INF:BANDWIDTH=#{variant[:bandwidth]},RESOLUTION=#{variant[:width]}x#{variant[:height]}"
        lines << "#{variant[:name]}/stream.m3u8"
      end

      File.write(master_path, lines.join("\n") + "\n")
      Rails.logger.info("[HlsService] Wrote master playlist: #{master_path}")
    end

    def source_width
      @source_width ||= @video.source_resolution[0] || 0
    end

    def source_height
      @source_height ||= @video.source_resolution[1] || 0
    end

    def hardware_encoder_available?
      return @hw_available if defined?(@hw_available)

      @hw_available = begin
        output, _, _ = Open3.capture3("#{@ffmpeg_path} -encoders")
        output.include?("h264_videotoolbox")
      rescue StandardError
        false
      end
    end

    def find_ffmpeg
      [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        `which ffmpeg 2>/dev/null`.strip
      ].find { |p| p.present? && File.executable?(p) } || "ffmpeg"
    end
  end
end
