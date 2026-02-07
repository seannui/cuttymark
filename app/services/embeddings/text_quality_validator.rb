module Embeddings
  module TextQualityValidator
    MIN_LENGTH_FOR_HEURISTICS = 500
    MAX_TEXT_LENGTH = 30_000
    MIN_SPACE_RATIO = 0.05
    MAX_TRIGRAM_FREQUENCY = 0.20

    # Returns [valid, reason] where reason is nil if valid
    def validate_text_quality(text)
      return [false, "blank"] if text.blank?

      if text.length > MAX_TEXT_LENGTH
        return [false, "too_long (#{text.length} chars)"]
      end

      if text.length > MIN_LENGTH_FOR_HEURISTICS
        space_ratio = text.count(" ").to_f / text.length
        if space_ratio < MIN_SPACE_RATIO
          return [false, "low_space_ratio (#{(space_ratio * 100).round(1)}%)"]
        end

        if repetitive_content?(text)
          return [false, "repetitive_content"]
        end
      end

      [true, nil]
    end

    private

    def repetitive_content?(text)
      words = text.split
      return false if words.length < 6

      # Build trigrams from words
      trigrams = words.each_cons(3).map { |trio| trio.join(" ") }
      return false if trigrams.empty?

      # Count frequencies
      counts = Hash.new(0)
      trigrams.each { |t| counts[t] += 1 }

      max_count = counts.values.max
      max_count.to_f / trigrams.length > MAX_TRIGRAM_FREQUENCY
    end
  end
end
