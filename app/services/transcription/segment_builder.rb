module Transcription
  class SegmentBuilder
    SENTENCE_ENDINGS = /[.!?]+\s*$/
    PARAGRAPH_PAUSE_THRESHOLD = 2.0  # seconds
    MIN_SENTENCE_WORDS = 3

    def initialize(transcript)
      @transcript = transcript
    end

    def build_from_whisper_result(result)
      ActiveRecord::Base.transaction do
        # Store raw text
        @transcript.update!(raw_text: result.text)

        # Create word-level segments
        word_segments = create_word_segments(result.words)

        # Build sentences from words
        sentence_segments = create_sentence_segments(word_segments)

        # Build paragraphs from sentences
        paragraph_segments = create_paragraph_segments(sentence_segments)

        {
          words: word_segments.count,
          sentences: sentence_segments.count,
          paragraphs: paragraph_segments.count
        }
      end
    end

    private

    def create_word_segments(words)
      return [] if words.empty?

      words.map do |word|
        @transcript.segments.create!(
          text: word.text,
          start_time: word.start_time,
          end_time: word.end_time,
          confidence: word.confidence,
          segment_type: "word"
        )
      end
    end

    def create_sentence_segments(word_segments)
      return [] if word_segments.empty?

      sentences = []
      current_sentence_words = []

      word_segments.each do |word_segment|
        current_sentence_words << word_segment

        # Check if this word ends a sentence
        if sentence_ending?(word_segment.text) && current_sentence_words.size >= MIN_SENTENCE_WORDS
          sentences << create_sentence_from_words(current_sentence_words)
          current_sentence_words = []
        end
      end

      # Handle remaining words as final sentence
      if current_sentence_words.any?
        sentences << create_sentence_from_words(current_sentence_words)
      end

      sentences
    end

    def create_sentence_from_words(word_segments)
      text = word_segments.map(&:text).join(" ").strip
      # Clean up spacing around punctuation
      text = text.gsub(/\s+([.,!?;:])/, '\1')

      avg_confidence = word_segments.sum(&:confidence).to_f / word_segments.size

      @transcript.segments.create!(
        text: text,
        start_time: word_segments.first.start_time,
        end_time: word_segments.last.end_time,
        confidence: avg_confidence,
        segment_type: "sentence"
      )
    end

    def create_paragraph_segments(sentence_segments)
      return [] if sentence_segments.empty?

      paragraphs = []
      current_paragraph_sentences = []

      sentence_segments.each_with_index do |sentence, index|
        current_paragraph_sentences << sentence

        # Check for paragraph break (long pause before next sentence)
        next_sentence = sentence_segments[index + 1]
        if next_sentence.nil? || paragraph_break?(sentence, next_sentence)
          paragraphs << create_paragraph_from_sentences(current_paragraph_sentences)
          current_paragraph_sentences = []
        end
      end

      paragraphs
    end

    def create_paragraph_from_sentences(sentence_segments)
      text = sentence_segments.map(&:text).join(" ")
      avg_confidence = sentence_segments.sum(&:confidence).to_f / sentence_segments.size

      @transcript.segments.create!(
        text: text,
        start_time: sentence_segments.first.start_time,
        end_time: sentence_segments.last.end_time,
        confidence: avg_confidence,
        segment_type: "paragraph"
      )
    end

    def sentence_ending?(text)
      text.to_s.match?(SENTENCE_ENDINGS)
    end

    def paragraph_break?(current_sentence, next_sentence)
      gap = next_sentence.start_time - current_sentence.end_time
      gap >= PARAGRAPH_PAUSE_THRESHOLD
    end
  end
end
