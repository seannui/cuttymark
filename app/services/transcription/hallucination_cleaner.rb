module Transcription
  class HallucinationCleaner
    # Thresholds for detecting hallucinations
    MIN_WORD_CONFIDENCE = 0.3
    MAX_OVERLAP_RATIO = 0.5  # If >50% of segment overlaps with another, it's suspicious
    REPETITION_WINDOW = 10   # Look for repeated phrases within N segments
    MIN_REPETITION_COUNT = 3 # Phrase repeated this many times is suspicious

    def initialize(transcript)
      @transcript = transcript
      @stats = { removed_overlapping: 0, removed_low_confidence: 0, removed_duplicates: 0, removed_repetitions: 0 }
    end

    def clean!
      Rails.logger.info("Starting hallucination cleanup for transcript #{@transcript.id}")

      ActiveRecord::Base.transaction do
        remove_duplicate_segments
        remove_overlapping_segments
        remove_low_confidence_segments
        remove_repetition_loops
        rebuild_sentences_and_paragraphs
      end

      Rails.logger.info("Cleanup complete: #{@stats}")
      @stats
    end

    private

    def remove_duplicate_segments
      # Find exact duplicate word segments (same text, same timestamps)
      word_segments = @transcript.segments.where(segment_type: "word")

      duplicates = word_segments
        .group(:text, :start_time, :end_time)
        .having("count(*) > 1")
        .pluck(:text, :start_time, :end_time)

      duplicates.each do |text, start_time, end_time|
        # Keep the first one, delete the rest
        segments_to_delete = word_segments
          .where(text: text, start_time: start_time, end_time: end_time)
          .order(:id)
          .offset(1)

        count = segments_to_delete.count
        segments_to_delete.delete_all
        @stats[:removed_duplicates] += count
      end
    end

    def remove_overlapping_segments
      # For word segments with overlapping time ranges, keep the one with higher confidence
      word_segments = @transcript.segments.where(segment_type: "word").order(:start_time, :id)

      segments_to_delete = []
      processed_ids = Set.new

      word_segments.each do |segment|
        next if processed_ids.include?(segment.id)

        # Find overlapping segments
        overlapping = word_segments
          .where.not(id: segment.id)
          .where("start_time < ? AND end_time > ?", segment.end_time, segment.start_time)
          .where.not(id: segments_to_delete)

        overlapping.each do |other|
          next if processed_ids.include?(other.id)

          # Calculate overlap ratio
          overlap_start = [segment.start_time, other.start_time].max
          overlap_end = [segment.end_time, other.end_time].min
          overlap_duration = overlap_end - overlap_start

          segment_duration = segment.end_time - segment.start_time
          other_duration = other.end_time - other.start_time

          # If significant overlap, keep the higher confidence one
          if overlap_duration > 0
            segment_overlap_ratio = overlap_duration / [segment_duration, 0.01].max
            other_overlap_ratio = overlap_duration / [other_duration, 0.01].max

            if segment_overlap_ratio > MAX_OVERLAP_RATIO || other_overlap_ratio > MAX_OVERLAP_RATIO
              # Keep the one with higher confidence, or longer duration if confidence is similar
              if (other.confidence || 0) > (segment.confidence || 0) + 0.1
                segments_to_delete << segment.id
                processed_ids << segment.id
              elsif (segment.confidence || 0) > (other.confidence || 0) + 0.1
                segments_to_delete << other.id
                processed_ids << other.id
              elsif other_duration > segment_duration
                segments_to_delete << segment.id
                processed_ids << segment.id
              else
                segments_to_delete << other.id
                processed_ids << other.id
              end
            end
          end
        end
      end

      if segments_to_delete.any?
        @stats[:removed_overlapping] = segments_to_delete.size
        @transcript.segments.where(id: segments_to_delete).delete_all
      end
    end

    def remove_low_confidence_segments
      # Remove word segments with very low confidence
      deleted = @transcript.segments
        .where(segment_type: "word")
        .where("confidence IS NOT NULL AND confidence < ?", MIN_WORD_CONFIDENCE)
        .delete_all

      @stats[:removed_low_confidence] = deleted
    end

    def remove_repetition_loops
      # Detect and remove repetition loops (same phrase repeated many times in sequence)
      word_segments = @transcript.segments.where(segment_type: "word").order(:start_time)
      texts = word_segments.pluck(:id, :text)

      segments_to_delete = Set.new

      # Look for repeated sequences
      texts.each_with_index do |(id, text), index|
        next if text.to_s.length < 2  # Skip punctuation

        # Count how many times this exact text appears in the next N segments
        window = texts[index, REPETITION_WINDOW * 2]
        repetition_count = window.count { |_, t| t == text }

        if repetition_count >= MIN_REPETITION_COUNT
          # This is likely a hallucination loop - mark all but first occurrence for deletion
          occurrences = window.select { |_, t| t == text }
          occurrences[1..].each { |seg_id, _| segments_to_delete << seg_id }
        end
      end

      if segments_to_delete.any?
        @stats[:removed_repetitions] = segments_to_delete.size
        @transcript.segments.where(id: segments_to_delete.to_a).delete_all
      end
    end

    def rebuild_sentences_and_paragraphs
      # Delete existing sentence and paragraph segments
      @transcript.segments.where(segment_type: %w[sentence paragraph]).delete_all

      # Rebuild using the cleaned word segments
      word_segments = @transcript.segments.where(segment_type: "word").order(:start_time)

      return if word_segments.empty?

      # Group into sentences
      sentence_segments = build_sentences(word_segments)

      # Group into paragraphs
      build_paragraphs(sentence_segments)
    end

    def build_sentences(word_segments)
      sentences = []
      current_words = []

      word_segments.each do |word|
        current_words << word

        if word.text.to_s.match?(/[.!?]+\s*$/) && current_words.size >= 3
          sentences << create_sentence(current_words)
          current_words = []
        end
      end

      # Handle remaining words
      sentences << create_sentence(current_words) if current_words.any?

      sentences
    end

    def create_sentence(words)
      text = words.map(&:text).join(" ").strip.gsub(/\s+([.,!?;:])/, '\1')
      avg_confidence = words.sum { |w| w.confidence || 0 } / words.size.to_f

      @transcript.segments.create!(
        text: text,
        start_time: words.first.start_time,
        end_time: words.last.end_time,
        confidence: avg_confidence,
        segment_type: "sentence"
      )
    end

    def build_paragraphs(sentence_segments)
      return if sentence_segments.empty?

      paragraphs = []
      current_sentences = []

      sentence_segments.each_with_index do |sentence, index|
        current_sentences << sentence

        next_sentence = sentence_segments[index + 1]
        if next_sentence.nil? || (next_sentence.start_time - sentence.end_time) >= 2.0
          paragraphs << create_paragraph(current_sentences)
          current_sentences = []
        end
      end

      paragraphs
    end

    def create_paragraph(sentences)
      text = sentences.map(&:text).join(" ")
      avg_confidence = sentences.sum(&:confidence) / sentences.size.to_f

      @transcript.segments.create!(
        text: text,
        start_time: sentences.first.start_time,
        end_time: sentences.last.end_time,
        confidence: avg_confidence,
        segment_type: "paragraph"
      )
    end
  end
end
