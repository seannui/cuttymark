class Match < ApplicationRecord
  belongs_to :search_query
  belongs_to :segment
  has_one :clip, dependent: :nullify

  validates :relevance_score, presence: true

  scope :ordered_by_relevance, -> { order(relevance_score: :desc) }
  scope :high_relevance, -> { where("relevance_score >= ?", 0.7) }

  delegate :video, to: :segment
  delegate :transcript, to: :segment
  delegate :project, to: :search_query

  def time_range
    segment.start_time..segment.end_time
  end

  def has_clip?
    clip.present?
  end
end
