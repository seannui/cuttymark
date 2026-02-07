module Search
  class KeywordSearch
    DEFAULT_LIMIT = 50

    def search(search_query, limit: DEFAULT_LIMIT)
      query_text = search_query.query_text.strip
      project = search_query.project

      case search_query.match_type
      when "exact"
        exact_search(search_query, project, query_text, limit)
      when "fuzzy"
        fuzzy_search(search_query, project, query_text, limit)
      else
        []
      end
    end

    # Used by hybrid search to find text matches for semantic queries
    # Prioritizes exact phrase matches, then individual word matches
    def search_fuzzy_for_hybrid(search_query, limit: DEFAULT_LIMIT)
      query_text = search_query.query_text.strip
      project = search_query.project

      # First: exact phrase matches (highest priority)
      exact_matches = exact_search(search_query, project, query_text, limit)
      return exact_matches if exact_matches.size >= limit

      # Second: word-level matches via plainto_tsquery
      remaining = limit - exact_matches.size
      word_matches = word_search(search_query, project, query_text, remaining)

      exact_matches + word_matches
    end

    private

    def transcripts_scope(project)
      Transcript.joins(:video)
                .where(videos: { project_id: project.id })
                .where.not(raw_text: nil)
                .where.not(search_vector: nil)
    end

    def exact_search(search_query, project, query_text, limit)
      scope = transcripts_scope(project)

      # Use phraseto_tsquery to preserve word order
      matching_transcripts = scope
        .where("search_vector @@ phraseto_tsquery('english', ?)", query_text)
        .limit(limit)

      create_matches_from_transcripts(search_query, matching_transcripts, query_text) do |raw_text|
        calculate_exact_relevance(raw_text, query_text)
      end
    end

    def fuzzy_search(search_query, project, query_text, limit)
      if trigram_available?
        fuzzy_search_trigram(search_query, project, query_text, limit)
      else
        word_search(search_query, project, query_text, limit)
      end
    end

    def fuzzy_search_trigram(search_query, project, query_text, limit)
      scope = transcripts_scope(project)

      matching_transcripts = scope
        .select("transcripts.*, similarity(LOWER(transcripts.raw_text), #{ActiveRecord::Base.connection.quote(query_text.downcase)}) AS sim_score")
        .where("LOWER(transcripts.raw_text) % ?", query_text.downcase)
        .order("sim_score DESC")
        .limit(limit)

      create_matches_from_transcripts(search_query, matching_transcripts, query_text) do |_raw_text, transcript|
        transcript.respond_to?(:sim_score) ? transcript.sim_score : 0.5
      end
    end

    def word_search(search_query, project, query_text, limit)
      scope = transcripts_scope(project)

      # Use plainto_tsquery — AND-combined terms, any order
      matching_transcripts = scope
        .where("search_vector @@ plainto_tsquery('english', ?)", query_text)
        .limit(limit)

      already_matched_transcript_ids = search_query.matches
        .joins(segment: :transcript)
        .pluck("transcripts.id")
        .uniq

      matching_transcripts = matching_transcripts.where.not(id: already_matched_transcript_ids) if already_matched_transcript_ids.any?

      words = query_text.downcase.split(/\s+/).reject(&:blank?)
      create_matches_from_transcripts(search_query, matching_transcripts, query_text) do |raw_text|
        calculate_fuzzy_relevance(raw_text, words)
      end
    end

    # Given matching transcripts, find the best segment in each and create Match records
    def create_matches_from_transcripts(search_query, transcripts, query_text, &relevance_calculator)
      transcripts.filter_map do |transcript|
        segment = find_best_segment(transcript, query_text)
        next unless segment
        next if search_query.matches.exists?(segment: segment)

        relevance = relevance_calculator.call(transcript.raw_text, transcript)
        context = build_context(segment, query_text)

        search_query.matches.create!(
          segment: segment,
          relevance_score: relevance,
          context_text: context
        )
      end
    end

    # Find the best sentence segment matching the query within a transcript
    def find_best_segment(transcript, query_text)
      sentences = transcript.sentence_segments.ordered
      return sentences.first if sentences.empty?

      query_lower = query_text.downcase

      # Strategy 1: Direct ILIKE on segment text (works when segments have proper spacing)
      direct_match = sentences.find { |s| s.text.downcase.include?(query_lower) }
      return direct_match if direct_match

      # Strategy 2: Use ts_headline to find the position in raw_text,
      # then find the segment whose time range overlaps that position
      headline = headline_snippet(transcript, query_text)
      if headline.present?
        # Extract a meaningful fragment from the headline to match against segments
        # ts_headline wraps matches in <b>...</b>, get surrounding text
        clean_headline = headline.gsub(/<\/?b>/, "").strip
        segment_by_text = sentences.find { |s| clean_headline.downcase.include?(s.text.downcase.first(40)) }
        return segment_by_text if segment_by_text
      end

      # Strategy 3: Fall back to first sentence segment
      sentences.first
    end

    def headline_snippet(transcript, query_text)
      result = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT ts_headline('english', ?, phraseto_tsquery('english', ?), 'MaxWords=35, MinWords=15, StartSel=<b>, StopSel=</b>')",
          transcript.raw_text,
          query_text
        ])
      )
      result
    rescue StandardError
      nil
    end

    def calculate_exact_relevance(text, query)
      query_lower = query.downcase
      text_lower = text.downcase
      occurrences = text_lower.scan(query_lower).size
      length_factor = 1.0 / Math.log(text.length + 1)
      [occurrences * 0.3 + length_factor * 0.7, 1.0].min
    end

    def calculate_fuzzy_relevance(text, words)
      text_lower = text.downcase
      matches = words.count { |word| text_lower.include?(word) }
      matches.to_f / words.size
    end

    def build_context(segment, query_text = nil)
      transcript = segment.transcript
      raw_text = transcript.raw_text

      # Prefer extracting context from raw_text (properly spaced)
      if raw_text.present? && query_text.present?
        excerpt = extract_raw_text_excerpt(raw_text, query_text)
        return excerpt if excerpt.present?
      end

      # Fall back to surrounding sentence segments
      sentences = transcript.sentence_segments.ordered
      current_index = sentences.find_index { |s| s.id == segment.id }
      return segment.text unless current_index

      start_index = [current_index - 1, 0].max
      end_index = [current_index + 1, sentences.size - 1].min

      sentences[start_index..end_index].map(&:text).join(" ")
    end

    # Extract a window of text from raw_text centered on the query match
    def extract_raw_text_excerpt(raw_text, query_text, context_chars: 150)
      pos = raw_text.downcase.index(query_text.downcase)
      return nil unless pos

      # Expand to sentence boundaries
      excerpt_start = [pos - context_chars, 0].max
      excerpt_end = [pos + query_text.length + context_chars, raw_text.length].min

      # Try to snap to sentence boundaries
      sentence_start = raw_text.rindex(/[.!?]\s/, excerpt_start)
      excerpt_start = sentence_start + 2 if sentence_start && sentence_start >= excerpt_start - 50

      sentence_end = raw_text.index(/[.!?]/, excerpt_end - 1)
      excerpt_end = sentence_end + 1 if sentence_end && sentence_end <= excerpt_end + 50

      raw_text[excerpt_start...excerpt_end].strip
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
