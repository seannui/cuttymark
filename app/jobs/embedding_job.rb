class EmbeddingJob < ApplicationJob
  queue_as :default

  retry_on Embeddings::OllamaClient::ConnectionError, wait: 30.seconds, attempts: 3

  def perform(transcript_id)
    transcript = Transcript.find(transcript_id)

    Rails.logger.info("[EmbeddingJob] Starting for transcript: #{transcript.id}")

    service = Embeddings::EmbeddingService.new
    stats = service.generate_for_transcript(transcript)

    Rails.logger.info("[EmbeddingJob] Completed for transcript: #{transcript.id} | #{stats.inspect}")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[EmbeddingJob] Transcript not found: #{transcript_id}")
    raise e
  rescue Embeddings::OllamaClient::ConnectionError
    raise # Let retry_on handle connection errors
  rescue StandardError => e
    Rails.logger.error("[EmbeddingJob] Failed for transcript #{transcript_id}: #{e.class} - #{e.message}")
    begin
      transcript&.fail! if transcript&.may_fail?
    rescue => state_error
      Rails.logger.error("[EmbeddingJob] Could not transition transcript to failed: #{state_error.message}")
    end
    raise e
  end
end
