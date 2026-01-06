class Transcript < ApplicationRecord
  include AASM

  belongs_to :video
  has_many :segments, dependent: :destroy
  has_many :word_segments, -> { where(segment_type: "word") }, class_name: "Segment"
  has_many :sentence_segments, -> { where(segment_type: "sentence") }, class_name: "Segment"
  has_many :paragraph_segments, -> { where(segment_type: "paragraph") }, class_name: "Segment"

  aasm column: :state do
    state :pending, initial: true
    state :processing
    state :segmenting
    state :embedding
    state :completed
    state :failed

    event :start_processing do
      transitions from: :pending, to: :processing
    end

    event :start_segmenting do
      transitions from: :processing, to: :segmenting
    end

    event :start_embedding do
      transitions from: :segmenting, to: :embedding
    end

    event :complete do
      transitions from: [:processing, :segmenting, :embedding], to: :completed
    end

    event :fail do
      transitions from: [:pending, :processing, :segmenting, :embedding], to: :failed
    end
  end

  def duration
    return 0 unless segments.any?

    segments.maximum(:end_time).to_f - segments.minimum(:start_time).to_f
  end

  def word_count
    word_segments.count
  end

  def sentence_count
    sentence_segments.count
  end

  def clean_hallucinations!
    Transcription::HallucinationCleaner.new(self).clean!
  end
end
