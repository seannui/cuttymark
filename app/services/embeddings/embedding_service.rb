module Embeddings
  class EmbeddingService
    include TextQualityValidator

    class Error < StandardError; end

    BATCH_SIZE = 32

    def initialize(ollama_client: nil)
      @ollama = ollama_client || OllamaClient.new
    end

    def generate_for_transcript(transcript)
      Rails.logger.info("Generating embeddings for transcript: #{transcript.id}")

      transcript.start_embedding! if transcript.may_start_embedding?

      # Get sentence segments that need embeddings
      segments = transcript.sentence_segments.where(embedding: nil)
      total = segments.count

      Rails.logger.info("Processing #{total} segments")

      stats = { embedded: 0, skipped_quality: 0, skipped_blank: 0, failed: 0 }

      segments.find_each.with_index do |segment, index|
        embed_segment_safely(segment, stats)

        if (index + 1) % 10 == 0
          Rails.logger.info("Progress: #{index + 1}/#{total} | #{stats.inspect}")
        end
      end

      Rails.logger.info("Embedding generation complete for transcript: #{transcript.id} | #{stats.inspect}")

      transcript.complete! if transcript.may_complete?

      stats
    end

    def generate_for_segment(segment)
      return if segment.embedding.present?

      valid, reason = validate_text_quality(segment.text)
      unless valid
        Rails.logger.info("Skipping segment #{segment.id}: #{reason}")
        return nil
      end

      embedding = @ollama.embed(segment.text)
      segment.update!(embedding: embedding) if embedding
      embedding
    rescue OllamaClient::InputTooLargeError => e
      Rails.logger.warn("Segment #{segment.id} too large for embedding: #{e.message}")
      nil
    rescue OllamaClient::Error => e
      Rails.logger.error("Failed to embed segment #{segment.id}: #{e.message}")
      nil
    end

    def generate_for_query(search_query)
      return search_query.query_embedding if search_query.query_embedding.present?

      embedding = @ollama.embed(search_query.query_text)
      search_query.update!(query_embedding: embedding) if embedding
      embedding
    end

    def ollama_available?
      @ollama.health_check
    end

    def backfill_missing_embeddings(project: nil)
      scope = Segment.sentences.where(embedding: nil)
      scope = scope.joins(transcript: :video).where(videos: { project_id: project.id }) if project

      total = scope.count
      stats = { embedded: 0, skipped_quality: 0, skipped_blank: 0, failed: 0 }

      Rails.logger.info("Backfilling #{total} missing embeddings")

      scope.find_each do |segment|
        embed_segment_safely(segment, stats)

        processed = stats[:embedded] + stats[:skipped_quality] + stats[:skipped_blank] + stats[:failed]
        if processed % 50 == 0
          Rails.logger.info("Backfill progress: #{processed}/#{total} | #{stats.inspect}")
        end
      end

      stats
    end

    private

    def embed_segment_safely(segment, stats)
      if segment.text.blank?
        stats[:skipped_blank] += 1
        return
      end

      valid, reason = validate_text_quality(segment.text)
      unless valid
        Rails.logger.info("Skipping segment #{segment.id} (quality): #{reason}")
        stats[:skipped_quality] += 1
        return
      end

      embedding = @ollama.embed(segment.text)
      if embedding
        segment.update!(embedding: embedding)
        stats[:embedded] += 1
      end
    rescue OllamaClient::InputTooLargeError => e
      Rails.logger.warn("Segment #{segment.id} input too large: #{e.message}")
      stats[:skipped_quality] += 1
    rescue OllamaClient::ConnectionError
      raise # Let connection errors bubble up for retry
    rescue OllamaClient::Error => e
      Rails.logger.error("Failed to embed segment #{segment.id}: #{e.message}")
      stats[:failed] += 1
    end
  end
end
