module Search
  class KeywordSearch
    DEFAULT_LIMIT = 50

    def search(search_query, limit: DEFAULT_LIMIT)
      query_text = search_query.query_text.downcase.strip
      segments_scope = searchable_segments(search_query.project)

      case search_query.match_type
      when "exact"
        exact_search(search_query, segments_scope, query_text, limit)
      when "fuzzy"
        fuzzy_search(search_query, segments_scope, query_text, limit)
      else
        []
      end
    end

    # Used by hybrid search to find text matches for semantic queries
    def search_fuzzy_for_hybrid(search_query, limit: DEFAULT_LIMIT)
      query_text = search_query.query_text.downcase.strip
      segments_scope = searchable_segments(search_query.project)
      fuzzy_search(search_query, segments_scope, query_text, limit)
    end

    private

    def searchable_segments(project)
      Segment.joins(transcript: :video)
             .where(videos: { project_id: project.id })
             .where(segment_type: "sentence")
    end

    def exact_search(search_query, scope, query_text, limit)
      # Case-insensitive exact match
      matching_segments = scope.where("LOWER(text) LIKE ?", "%#{query_text}%")
                               .limit(limit)

      create_matches(search_query, matching_segments) do |segment|
        calculate_exact_relevance(segment.text, query_text)
      end
    end

    def fuzzy_search(search_query, scope, query_text, limit)
      # Use PostgreSQL trigram similarity if available, otherwise fall back to LIKE
      if trigram_available?
        fuzzy_search_trigram(search_query, scope, query_text, limit)
      else
        fuzzy_search_fallback(search_query, scope, query_text, limit)
      end
    end

    def fuzzy_search_trigram(search_query, scope, query_text, limit)
      # PostgreSQL trigram similarity
      matching_segments = scope
        .select("segments.*, similarity(LOWER(text), #{ActiveRecord::Base.connection.quote(query_text)}) AS sim_score")
        .where("LOWER(text) % ?", query_text)
        .order("sim_score DESC")
        .limit(limit)

      create_matches(search_query, matching_segments) do |segment|
        segment.respond_to?(:sim_score) ? segment.sim_score : 0.5
      end
    end

    def fuzzy_search_fallback(search_query, scope, query_text, limit)
      # Split query into words and search for any
      words = query_text.split(/\s+/).reject(&:blank?)
      return [] if words.empty?

      conditions = words.map { "LOWER(text) LIKE ?" }.join(" OR ")
      values = words.map { |w| "%#{w}%" }

      matching_segments = scope.where(conditions, *values).limit(limit)

      create_matches(search_query, matching_segments) do |segment|
        calculate_fuzzy_relevance(segment.text, words)
      end
    end

    def create_matches(search_query, segments, &relevance_calculator)
      segments.map do |segment|
        next if search_query.matches.exists?(segment: segment)

        relevance = relevance_calculator.call(segment)
        context = build_context(segment)

        search_query.matches.create!(
          segment: segment,
          relevance_score: relevance,
          context_text: context
        )
      end.compact
    end

    def calculate_exact_relevance(text, query)
      # Higher score for more occurrences and shorter text (more relevant)
      occurrences = text.downcase.scan(query).size
      length_factor = 1.0 / Math.log(text.length + 1)
      [occurrences * 0.3 + length_factor * 0.7, 1.0].min
    end

    def calculate_fuzzy_relevance(text, words)
      text_lower = text.downcase
      matches = words.count { |word| text_lower.include?(word) }
      matches.to_f / words.size
    end

    def build_context(segment)
      transcript = segment.transcript
      sentences = transcript.sentence_segments.ordered

      current_index = sentences.find_index { |s| s.id == segment.id }
      return segment.text unless current_index

      start_index = [current_index - 1, 0].max
      end_index = [current_index + 1, sentences.size - 1].min

      sentences[start_index..end_index].map(&:text).join(" ")
    end

    def trigram_available?
      @trigram_available ||= begin
        ActiveRecord::Base.connection.execute("SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'").any?
      rescue StandardError
        false
      end
    end
  end
end
