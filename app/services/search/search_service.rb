module Search
  class SearchService
    def initialize(semantic_search: nil, keyword_search: nil)
      @semantic_search = semantic_search || SemanticSearch.new
      @keyword_search = keyword_search || KeywordSearch.new
    end

    def execute(search_query, limit: 50, threshold: 0.35)
      Rails.logger.info("Executing search: '#{search_query.query_text}' (#{search_query.match_type})")

      matches = case search_query.match_type
      when "semantic"
        # Combine semantic and keyword search for better results
        # This ensures exact text matches are always found, plus semantic matches
        hybrid_search(search_query, limit: limit, threshold: threshold)
      when "exact", "fuzzy"
        @keyword_search.search(search_query, limit: limit)
      else
        Rails.logger.warn("Unknown match type: #{search_query.match_type}")
        []
      end

      Rails.logger.info("Found #{matches.size} matches")
      matches
    end

    private

    def hybrid_search(search_query, limit:, threshold:)
      # First, find keyword matches (these are most relevant for exact phrases)
      keyword_matches = @keyword_search.search_fuzzy_for_hybrid(search_query, limit: limit)
      Rails.logger.info("Keyword matches: #{keyword_matches.size}")

      # Then get semantic matches
      semantic_matches = @semantic_search.search(search_query, limit: limit, threshold: threshold)
      Rails.logger.info("Semantic matches: #{semantic_matches.size}")

      # Combine and dedupe (keyword matches get boosted scores)
      combined = {}

      # Add keyword matches with boosted score
      keyword_matches.each do |match|
        combined[match.segment_id] = match
        # Boost keyword match scores
        if match.relevance_score < 0.8
          match.update(relevance_score: [match.relevance_score + 0.3, 1.0].min)
        end
      end

      # Add semantic matches that aren't already found
      semantic_matches.each do |match|
        combined[match.segment_id] ||= match
      end

      # Sort by relevance and return
      combined.values.sort_by { |m| -m.relevance_score }.first(limit)
    end
  end
end
