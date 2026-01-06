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

  # Time it took to transcribe (in seconds)
  def transcription_duration
    return nil unless transcription_started_at && transcription_completed_at

    transcription_completed_at - transcription_started_at
  end

  # Formatted transcription duration
  def transcription_duration_formatted
    seconds = transcription_duration
    return nil unless seconds

    if seconds >= 3600
      hours = (seconds / 3600).to_i
      minutes = ((seconds % 3600) / 60).to_i
      secs = (seconds % 60).to_i
      format("%dh %dm %ds", hours, minutes, secs)
    elsif seconds >= 60
      minutes = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      format("%dm %ds", minutes, secs)
    else
      format("%.1fs", seconds)
    end
  end

  def clean_hallucinations!
    Transcription::HallucinationCleaner.new(self).clean!
  end
end
