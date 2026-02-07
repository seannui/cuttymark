class VideoReprocessJob < ApplicationJob
  queue_as :video_processing

  retry_on Transcription::BaseClient::ConnectionError, wait: 30.seconds, attempts: 3

  def perform(video_id, engine = nil)
    video = Video.find(video_id)

    # Skip if already transcribed with the requested engine
    if engine.present? && video.transcript&.completed? && video.transcript.engine == engine.to_s
      Rails.logger.info("[VideoReprocessJob] Skipping: #{video.filename} (#{video.id}) already transcribed with #{engine}")
      return
    end

    Rails.logger.info("[VideoReprocessJob] Starting: #{video.filename} (#{video.id}) engine=#{engine || 'default'}")

    transcript = video.retry!(engine: engine&.to_sym)

    Rails.logger.info("[VideoReprocessJob] Completed: #{video.filename} - #{transcript.segments.count} segments")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[VideoReprocessJob] Video not found: #{video_id}")
    raise e
  rescue StandardError => e
    Rails.logger.error("[VideoReprocessJob] Error processing video #{video_id}: #{e.message}")
    raise e
  end
end
