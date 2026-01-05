class Transcript < ApplicationRecord
  belongs_to :video
  has_many :segments, dependent: :destroy
  has_many :word_segments, -> { where(segment_type: "word") }, class_name: "Segment"
  has_many :sentence_segments, -> { where(segment_type: "sentence") }, class_name: "Segment"
  has_many :paragraph_segments, -> { where(segment_type: "paragraph") }, class_name: "Segment"

  validates :status, presence: true

  enum :status, {
    pending: "pending",
    processing: "processing",
    segmenting: "segmenting",
    embedding: "embedding",
    completed: "completed",
    failed: "failed"
  }, default: :pending

  scope :completed, -> { where(status: "completed") }
  scope :pending, -> { where(status: "pending") }
  scope :failed, -> { where(status: "failed") }

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
end
