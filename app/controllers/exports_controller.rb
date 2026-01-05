class ExportsController < ApplicationController
  before_action :set_clip, only: [:create]

  def new
    @clips = if params[:clip_ids].present?
               Clip.where(id: params[:clip_ids].split(","))
             elsif params[:video_id].present?
               Clip.where(video_id: params[:video_id])
             elsif params[:search_query_id].present?
               Clip.joins(:match).where(matches: { search_query_id: params[:search_query_id] })
             else
               Clip.none
             end

    @export_service = Export::ExportService.new
    @video_formats = @export_service.video_formats
    @edit_list_formats = @export_service.edit_list_formats
  end

  def create
    format = params[:format_type]&.to_sym

    unless format
      redirect_to @clip, alert: "Please select an export format."
      return
    end

    begin
      export_service = Export::ExportService.new
      output_path = export_service.export(@clip, format: format, name: @clip.title)

      if format.to_s.start_with?("mp4", "prores")
        @clip.update!(export_path: output_path, status: :rendered)
        redirect_to @clip, notice: "Clip exported successfully to: #{File.basename(output_path)}"
      else
        send_file output_path,
                  filename: File.basename(output_path),
                  type: content_type_for(format),
                  disposition: "attachment"
      end
    rescue Export::ExportService::Error, Export::FfmpegExportService::Error => e
      redirect_to @clip, alert: "Export failed: #{e.message}"
    end
  end

  def batch
    clip_ids = params[:clip_ids]
    formats = params[:formats]&.reject(&:blank?)

    if clip_ids.blank?
      redirect_back fallback_location: clips_path, alert: "No clips selected."
      return
    end

    if formats.blank?
      redirect_back fallback_location: clips_path, alert: "No formats selected."
      return
    end

    clips = Clip.where(id: clip_ids)
    name = params[:export_name].presence || "batch_export"

    BatchExportJob.perform_later(clips.map(&:id), formats, name)

    redirect_to clips_path, notice: "Batch export started for #{clips.size} clips in #{formats.size} formats."
  end

  private

  def set_clip
    @clip = Clip.find(params[:clip_id])
  end

  def content_type_for(format)
    case format.to_sym
    when :premiere_xml then "application/xml"
    when :fcpxml then "application/xml"
    when :edl then "text/plain"
    else "application/octet-stream"
    end
  end
end
