module Export
  class FfmpegExportService
    class Error < StandardError; end

    PRESETS = {
      copy: {
        description: "Stream copy (fastest, no re-encoding)",
        video_codec: "copy",
        audio_codec: "copy",
        extension: "mp4"
      },
      h264_high: {
        description: "H.264 High Quality",
        video_codec: "libx264",
        audio_codec: "aac",
        crf: 18,
        preset: "slow",
        audio_bitrate: "256k",
        extension: "mp4"
      },
      h264_medium: {
        description: "H.264 Medium Quality",
        video_codec: "libx264",
        audio_codec: "aac",
        crf: 23,
        preset: "medium",
        audio_bitrate: "192k",
        extension: "mp4"
      },
      h264_web: {
        description: "H.264 Web Optimized",
        video_codec: "libx264",
        audio_codec: "aac",
        crf: 28,
        preset: "fast",
        audio_bitrate: "128k",
        extension: "mp4"
      },
      prores_422: {
        description: "ProRes 422 (for editing)",
        video_codec: "prores_ks",
        video_profile: 2,
        audio_codec: "pcm_s16le",
        extension: "mov"
      },
      prores_hq: {
        description: "ProRes 422 HQ",
        video_codec: "prores_ks",
        video_profile: 3,
        audio_codec: "pcm_s16le",
        extension: "mov"
      },
      dnxhd: {
        description: "DNxHD (Avid compatible)",
        video_codec: "dnxhd",
        video_profile: "dnxhr_hq",
        audio_codec: "pcm_s16le",
        extension: "mxf"
      }
    }.freeze

    def initialize(ffmpeg_client: nil)
      @ffmpeg = ffmpeg_client || VideoProcessing::FfmpegClient.new
    end

    def export_clip(clip, preset: :copy, output_dir: nil)
      validate_clip!(clip)

      preset_config = PRESETS[preset.to_sym]
      raise Error, "Unknown preset: #{preset}" unless preset_config

      output_dir ||= default_output_dir
      FileUtils.mkdir_p(output_dir)

      output_filename = generate_filename(clip, preset_config[:extension])
      output_path = File.join(output_dir, output_filename)

      Rails.logger.info("[FfmpegExportService] Exporting clip #{clip.id} with preset: #{preset}")

      if preset.to_sym == :copy
        export_with_copy(clip, output_path)
      else
        export_with_reencode(clip, output_path, preset_config)
      end

      clip.update!(export_path: output_path, status: :rendered)
      output_path
    end

    def export_clips(clips, preset: :copy, output_dir: nil)
      results = { success: [], failed: [] }

      clips.each do |clip|
        begin
          path = export_clip(clip, preset: preset, output_dir: output_dir)
          results[:success] << { clip: clip, path: path }
        rescue Error, VideoProcessing::FfmpegClient::Error => e
          Rails.logger.error("[FfmpegExportService] Failed to export clip #{clip.id}: #{e.message}")
          results[:failed] << { clip: clip, error: e.message }
        end
      end

      results
    end

    def available_presets
      PRESETS.transform_values { |v| v[:description] }
    end

    private

    def validate_clip!(clip)
      raise Error, "Clip has no video" unless clip.video
      raise Error, "Video source not found" unless File.exist?(clip.source_path)
      raise Error, "Invalid time range" if clip.end_time <= clip.start_time
    end

    def export_with_copy(clip, output_path)
      @ffmpeg.render_clip(
        clip.source_path,
        output_path,
        start_time: clip.start_time,
        end_time: clip.end_time,
        codec: "copy"
      )
    end

    def export_with_reencode(clip, output_path, config)
      cmd = build_reencode_command(clip, output_path, config)
      execute_ffmpeg(cmd)
    end

    def build_reencode_command(clip, output_path, config)
      duration = clip.end_time - clip.start_time

      cmd = [
        ffmpeg_path,
        "-y",
        "-ss", clip.start_time.to_s,
        "-i", clip.source_path,
        "-t", duration.to_s
      ]

      # Video codec options
      cmd += ["-c:v", config[:video_codec]]
      cmd += ["-profile:v", config[:video_profile].to_s] if config[:video_profile]
      cmd += ["-crf", config[:crf].to_s] if config[:crf]
      cmd += ["-preset", config[:preset]] if config[:preset]

      # Audio codec options
      cmd += ["-c:a", config[:audio_codec]]
      cmd += ["-b:a", config[:audio_bitrate]] if config[:audio_bitrate]

      cmd << output_path
      cmd
    end

    def execute_ffmpeg(cmd)
      Rails.logger.debug { "FFmpeg command: #{cmd.join(' ')}" }

      output, error, status = Open3.capture3(*cmd)
      unless status.success?
        Rails.logger.error("FFmpeg error: #{error}")
        raise Error, "Export failed: #{error}"
      end
      output
    end

    def ffmpeg_path
      @ffmpeg_path ||= find_executable("ffmpeg")
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

    def generate_filename(clip, extension)
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      title_slug = clip.title.present? ? clip.title.parameterize : "clip"
      "#{title_slug}_#{clip.id}_#{timestamp}.#{extension}"
    end

    def default_output_dir
      Rails.root.join("storage", "exports").to_s
    end
  end
end
