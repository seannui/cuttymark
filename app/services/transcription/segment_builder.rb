module Transcription
  class SegmentBuilder
    SENTENCE_ENDINGS = /[.!?]+\s*$/
    PARAGRAPH_PAUSE_THRESHOLD = 2.0  # seconds
    MIN_SENTENCE_WORDS = 3

    # Hallucination detection thresholds
    MIN_WORD_CONFIDENCE = 0.3
    MAX_REPETITION_COUNT = 3  # Max times same word can appear in a row
    MIN_WORD_DURATION = 0.01  # Minimum realistic word duration in seconds
    MAX_WORD_DURATION = 10.0  # Maximum realistic word duration

    def initialize(transcript)
      @transcript = transcript
      @stats = { filtered_low_confidence: 0, filtered_overlapping: 0, filtered_repetitions: 0, filtered_invalid_duration: 0 }
    end

    def build_from_whisper_result(result)
      ActiveRecord::Base.transaction do
        # Store raw text
        @transcript.update!(raw_text: result.text)

        # Filter and create word-level segments
        filtered_words = filter_hallucinations(result.words)
        word_segments = create_word_segments(filtered_words)

        Rails.logger.info("SegmentBuilder filtering stats: #{@stats}")

        # Build sentences from words
        sentence_segments = create_sentence_segments(word_segments)

        # Build paragraphs from sentences
        paragraph_segments = create_paragraph_segments(sentence_segments)

        {
          words: word_segments.count,
          sentences: sentence_segments.count,
          paragraphs: paragraph_segments.count,
          filtered: @stats
        }
      end
    end

    private

    def filter_hallucinations(words)
      return [] if words.empty?

      filtered = []
      last_end_time = -1
      recent_texts = []

      words.each do |word|
        # Skip words with invalid timestamps
        duration = (word.end_time || 0) - (word.start_time || 0)
        if duration < MIN_WORD_DURATION || duration > MAX_WORD_DURATION
          @stats[:filtered_invalid_duration] += 1
          next
        end

        # Skip words with very low confidence
        if word.confidence && word.confidence < MIN_WORD_CONFIDENCE
          @stats[:filtered_low_confidence] += 1
          next
        end

        # Skip words that significantly overlap with previous words
        if word.start_time < last_end_time - 0.1  # Allow 100ms tolerance
          @stats[:filtered_overlapping] += 1
          next
        end

        # Skip repetition loops (same word repeated too many times)
        normalized_text = word.text.to_s.strip.downcase
        if recent_texts.count(normalized_text) >= MAX_REPETITION_COUNT
          @stats[:filtered_repetitions] += 1
          next
        end

        filtered << word
        last_end_time = word.end_time
        recent_texts << normalized_text
        recent_texts.shift if recent_texts.size > MAX_REPETITION_COUNT * 2
      end

      filtered
    end

    def create_word_segments(words)
      return [] if words.empty?

      words.map do |word|
        @transcript.segments.create!(
          text: word.text,
          start_time: word.start_time,
          end_time: word.end_time,
          confidence: word.confidence,
          speaker: word.speaker,
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

      # Determine speaker for sentence (most common speaker, or first if tied)
      speaker = dominant_speaker(word_segments)

      @transcript.segments.create!(
        text: text,
        start_time: word_segments.first.start_time,
        end_time: word_segments.last.end_time,
        confidence: avg_confidence,
        speaker: speaker,
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

      # For paragraphs, list all speakers or use dominant
      speaker = dominant_speaker(sentence_segments)

      @transcript.segments.create!(
        text: text,
        start_time: sentence_segments.first.start_time,
        end_time: sentence_segments.last.end_time,
        confidence: avg_confidence,
        speaker: speaker,
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

    def dominant_speaker(segments)
      speakers = segments.map(&:speaker).compact
      return nil if speakers.empty?

      # Find most common speaker
      speakers.tally.max_by { |_, count| count }&.first
    end
  end
end
