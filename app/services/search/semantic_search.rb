module Search
  class SemanticSearch
    DEFAULT_LIMIT = 50
    DEFAULT_THRESHOLD = 0.35  # Lowered from 0.5 for better recall

    def initialize(embedding_service: nil)
      @embedding_service = embedding_service || Embeddings::EmbeddingService.new
    end

    def search(search_query, limit: DEFAULT_LIMIT, threshold: DEFAULT_THRESHOLD)
      # Ensure query has embedding
      query_embedding = ensure_query_embedding(search_query)
      return [] unless query_embedding

      # Get segments to search (from project's videos)
      segments_scope = searchable_segments(search_query.project)

      # Perform vector similarity search using neighbor gem
      results = segments_scope
        .nearest_neighbors(:embedding, query_embedding, distance: "cosine")
        .limit(limit * 2)  # Get more to filter by threshold

      # Filter by threshold and create matches
      matches = []
      results.each do |segment|
        # neighbor gem returns distance, we want similarity (1 - distance for cosine)
        similarity = 1.0 - segment.neighbor_distance

        break if similarity < threshold

        match = create_match(search_query, segment, similarity)
        matches << match if match
      end

      matches.first(limit)
    end

    def find_similar_segments(segment, limit: 10)
      return [] unless segment.embedding.present?

      segment.nearest_neighbors(:embedding, distance: "cosine")
             .where.not(id: segment.id)
             .limit(limit)
    end

    private

    def ensure_query_embedding(search_query)
      search_query.query_embedding || @embedding_service.generate_for_query(search_query)
    end

    def searchable_segments(project)
      Segment.joins(transcript: :video)
             .where(videos: { project_id: project.id })
             .where(segment_type: "sentence")
             .where.not(embedding: nil)
    end

    def create_match(search_query, segment, similarity)
      # Check if match already exists
      existing = search_query.matches.find_by(segment: segment)
      return existing if existing

      # Build context (surrounding text)
      context = build_context(segment)

      search_query.matches.create!(
        segment: segment,
        relevance_score: similarity,
        context_text: context
      )
    end

    def build_context(segment)
      # Get surrounding sentences for context
      transcript = segment.transcript
      sentences = transcript.sentence_segments.ordered

      current_index = sentences.find_index { |s| s.id == segment.id }
      return segment.text unless current_index

      # Get 1 sentence before and after
      start_index = [current_index - 1, 0].max
      end_index = [current_index + 1, sentences.size - 1].min

      sentences[start_index..end_index].map(&:text).join(" ")
    end
  end
end
