class TranscriptionJob < ApplicationJob
  queue_as :default

  retry_on Transcription::WhisperClient::ConnectionError, wait: 30.seconds, attempts: 3
  discard_on Transcription::TranscriptionService::Error

  def perform(video_id)
    video = Video.find(video_id)

    Rails.logger.info("[TranscriptionJob] Starting for video: #{video.filename} (#{video.id})")

    service = Transcription::TranscriptionService.new
    transcript = service.transcribe(video)

    # Queue embedding generation after successful transcription
    EmbeddingJob.perform_later(transcript.id)

    Rails.logger.info("[TranscriptionJob] Completed for video: #{video.filename}")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[TranscriptionJob] Video not found: #{video_id}")
    raise e
  end
end
