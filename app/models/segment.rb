class Segment < ApplicationRecord
  belongs_to :transcript
  has_many :matches, dependent: :destroy

  has_neighbors :embedding

  validates :text, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validates :segment_type, presence: true

  enum :segment_type, {
    word: "word",
    sentence: "sentence",
    paragraph: "paragraph"
  }, default: :word

  scope :words, -> { where(segment_type: "word") }
  scope :sentences, -> { where(segment_type: "sentence") }
  scope :paragraphs, -> { where(segment_type: "paragraph") }
  scope :with_embeddings, -> { where.not(embedding: nil) }
  scope :ordered, -> { order(:start_time) }

  def duration
    end_time - start_time
  end

  def time_range_formatted
    format_time(start_time) + " - " + format_time(end_time)
  end

  def video
    transcript.video
  end

  def project
    video.project
  end

  private

  def format_time(seconds)
    mins = (seconds / 60).to_i
    secs = (seconds % 60).round(1)
    format("%<mins>d:%<secs>05.2f", mins: mins, secs: secs)
  end
end
