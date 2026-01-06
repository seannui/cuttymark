module Embeddings
  class EmbeddingService
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

      segments.find_each.with_index do |segment, index|
        embedding = @ollama.embed(segment.text)
        segment.update!(embedding: embedding) if embedding

        if (index + 1) % 10 == 0
          Rails.logger.info("Progress: #{index + 1}/#{total}")
        end
      end

      Rails.logger.info("Embedding generation complete for transcript: #{transcript.id}")

      segments.count
    end

    def generate_for_segment(segment)
      return if segment.embedding.present?

      embedding = @ollama.embed(segment.text)
      segment.update!(embedding: embedding) if embedding
      embedding
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
      processed = 0

      Rails.logger.info("Backfilling #{total} missing embeddings")

      scope.find_each do |segment|
        generate_for_segment(segment)
        processed += 1

        if processed % 50 == 0
          Rails.logger.info("Backfill progress: #{processed}/#{total}")
        end
      end

      processed
    end
  end
end
