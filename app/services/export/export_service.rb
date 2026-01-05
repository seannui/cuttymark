module Export
  class ExportService
    class Error < StandardError; end

    FORMATS = {
      # Video file exports
      mp4_copy: {
        type: :video,
        description: "MP4 (stream copy - fastest)",
        exporter: :ffmpeg,
        options: { preset: :copy }
      },
      mp4_high: {
        type: :video,
        description: "MP4 H.264 High Quality",
        exporter: :ffmpeg,
        options: { preset: :h264_high }
      },
      mp4_medium: {
        type: :video,
        description: "MP4 H.264 Medium Quality",
        exporter: :ffmpeg,
        options: { preset: :h264_medium }
      },
      mp4_web: {
        type: :video,
        description: "MP4 H.264 Web Optimized",
        exporter: :ffmpeg,
        options: { preset: :h264_web }
      },
      prores_422: {
        type: :video,
        description: "ProRes 422 (editing)",
        exporter: :ffmpeg,
        options: { preset: :prores_422 }
      },
      prores_hq: {
        type: :video,
        description: "ProRes 422 HQ",
        exporter: :ffmpeg,
        options: { preset: :prores_hq }
      },

      # Edit list exports
      premiere_xml: {
        type: :edit_list,
        description: "Adobe Premiere Pro XML",
        exporter: :premiere,
        extension: "xml"
      },
      fcpxml: {
        type: :edit_list,
        description: "Final Cut Pro X (FCPXML)",
        exporter: :fcpxml,
        extension: "fcpxml"
      },
      edl: {
        type: :edit_list,
        description: "EDL (CMX 3600)",
        exporter: :edl,
        extension: "edl"
      }
    }.freeze

    def initialize
      @ffmpeg_exporter = FfmpegExportService.new
      @premiere_exporter = PremiereXmlExporter.new
      @fcpxml_exporter = FcpxmlExporter.new
      @edl_exporter = EdlExporter.new
    end

    def export(clips, format:, output_path: nil, name: nil)
      clips = Array(clips)
      raise Error, "No clips to export" if clips.empty?

      format_config = FORMATS[format.to_sym]
      raise Error, "Unknown format: #{format}" unless format_config

      Rails.logger.info("[ExportService] Exporting #{clips.size} clips as #{format}")

      case format_config[:type]
      when :video
        export_video(clips, format_config, output_path)
      when :edit_list
        export_edit_list(clips, format_config, output_path, name)
      end
    end

    def export_batch(clips, formats:, output_dir: nil, name: nil)
      results = { success: [], failed: [] }

      formats.each do |format|
        begin
          path = export(clips, format: format, output_path: nil, name: name)
          results[:success] << { format: format, path: path }
        rescue Error, StandardError => e
          Rails.logger.error("[ExportService] Batch export failed for #{format}: #{e.message}")
          results[:failed] << { format: format, error: e.message }
        end
      end

      results
    end

    def available_formats
      FORMATS.transform_values { |v| v[:description] }
    end

    def video_formats
      FORMATS.select { |_, v| v[:type] == :video }.transform_values { |v| v[:description] }
    end

    def edit_list_formats
      FORMATS.select { |_, v| v[:type] == :edit_list }.transform_values { |v| v[:description] }
    end

    private

    def export_video(clips, format_config, output_dir)
      options = format_config[:options] || {}

      if clips.size == 1
        @ffmpeg_exporter.export_clip(clips.first, **options, output_dir: output_dir)
      else
        results = @ffmpeg_exporter.export_clips(clips, **options, output_dir: output_dir)
        results[:success].map { |r| r[:path] }
      end
    end

    def export_edit_list(clips, format_config, output_path, name)
      exporter = case format_config[:exporter]
                 when :premiere then @premiere_exporter
                 when :fcpxml then @fcpxml_exporter
                 when :edl then @edl_exporter
                 else raise Error, "Unknown exporter: #{format_config[:exporter]}"
                 end

      export_params = { output_path: output_path }

      case format_config[:exporter]
      when :premiere
        export_params[:sequence_name] = name
      when :fcpxml
        export_params[:project_name] = name
      when :edl
        export_params[:title] = name
      end

      exporter.export_clips(clips, **export_params)
    end
  end
end
