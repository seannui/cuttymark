class BatchExportJob < ApplicationJob
  queue_as :default

  def perform(clip_ids, formats, name = nil)
    clips = Clip.where(id: clip_ids).includes(:video)

    if clips.empty?
      Rails.logger.warn("[BatchExportJob] No clips found for IDs: #{clip_ids}")
      return
    end

    Rails.logger.info("[BatchExportJob] Starting batch export for #{clips.size} clips in #{formats.size} formats")

    export_service = Export::ExportService.new
    results = export_service.export_batch(clips, formats: formats.map(&:to_sym), name: name)

    Rails.logger.info("[BatchExportJob] Completed: #{results[:success].size} successful, #{results[:failed].size} failed")

    results[:failed].each do |failure|
      Rails.logger.error("[BatchExportJob] Failed format #{failure[:format]}: #{failure[:error]}")
    end

    results
  end
end
