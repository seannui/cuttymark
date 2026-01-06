class VideoReprocessJob < ApplicationJob
  queue_as :video_processing

  retry_on Transcription::BaseClient::ConnectionError, wait: 30.seconds, attempts: 3

  def perform(video_id)
    video = Video.find(video_id)
    Rails.logger.info("[VideoReprocessJob] Starting: #{video.filename} (#{video.id})")

    transcript = video.process!

    Rails.logger.info("[VideoReprocessJob] Completed: #{video.filename} - #{transcript.segments.count} segments")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[VideoReprocessJob] Video not found: #{video_id}")
    raise e
  rescue StandardError => e
    Rails.logger.error("[VideoReprocessJob] Error processing video #{video_id}: #{e.message}")
    raise e
  end
end
