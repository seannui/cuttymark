module VideoProcessing
  class ImportService
    class Error < StandardError; end

    def initialize(ffmpeg_client: nil)
      @ffmpeg = ffmpeg_client || FfmpegClient.new
    end

    def import(source_path, project:, filename: nil)
      raise Error, "File not found: #{source_path}" unless File.exist?(source_path)

      filename ||= File.basename(source_path)
      format = File.extname(source_path).delete(".").downcase

      # Check if already imported
      existing = ::Video.find_by(source_path: source_path)
      if existing
        Rails.logger.info("Video already imported: #{source_path}")
        return existing
      end

      # Get metadata
      metadata = @ffmpeg.get_metadata(source_path)

      video = ::Video.create!(
        project: project,
        source_path: source_path,
        filename: filename,
        format: format,
        duration_seconds: metadata.duration,
        file_size: metadata.file_size,
        status: determine_initial_status(format),
        metadata: build_metadata_hash(metadata)
      )

      Rails.logger.info("Imported video: #{video.filename} (#{video.id})")
      video
    end

    def import_directory(directory_path, project:, recursive: false, extensions: nil)
      raise Error, "Directory not found: #{directory_path}" unless Dir.exist?(directory_path)

      extensions ||= ::Video::SUPPORTED_FORMATS + [::Video::BRAW_FORMAT]
      pattern = recursive ? "**/*" : "*"

      imported = []
      skipped = []

      Dir.glob(File.join(directory_path, pattern)).each do |file_path|
        next unless File.file?(file_path)

        ext = File.extname(file_path).delete(".").downcase
        next unless extensions.include?(ext)

        begin
          video = import(file_path, project: project)
          imported << video
        rescue Error => e
          Rails.logger.warn("Skipped #{file_path}: #{e.message}")
          skipped << { path: file_path, error: e.message }
        end
      end

      { imported: imported, skipped: skipped }
    end

    private

    def determine_initial_status(format)
      if format == ::Video::BRAW_FORMAT
        "pending" # Needs proxy conversion
      else
        "ready"   # Can be processed directly
      end
    end

    def build_metadata_hash(metadata)
      {
        video_codec: metadata.video_codec,
        video_width: metadata.video_width,
        video_height: metadata.video_height,
        frame_rate: metadata.frame_rate,
        bit_rate: metadata.bit_rate,
        audio_codec: metadata.audio_codec,
        audio_sample_rate: metadata.audio_sample_rate,
        audio_channels: metadata.audio_channels
      }.compact
    end
  end
end
