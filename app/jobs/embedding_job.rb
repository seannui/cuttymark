class EmbeddingJob < ApplicationJob
  queue_as :default

  retry_on Embeddings::OllamaClient::ConnectionError, wait: 30.seconds, attempts: 3

  def perform(transcript_id)
    transcript = Transcript.find(transcript_id)

    Rails.logger.info("[EmbeddingJob] Starting for transcript: #{transcript.id}")

    service = Embeddings::EmbeddingService.new
    count = service.generate_for_transcript(transcript)

    Rails.logger.info("[EmbeddingJob] Generated #{count} embeddings for transcript: #{transcript.id}")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[EmbeddingJob] Transcript not found: #{transcript_id}")
    raise e
  end
end
