class Project < ApplicationRecord
  has_many :videos, dependent: :destroy
  has_many :search_queries, dependent: :destroy
  has_many :transcripts, through: :videos
  has_many :clips, through: :videos

  validates :name, presence: true

  def total_duration
    videos.sum(:duration_seconds)
  end

  def transcribed_videos_count
    videos.joins(:transcript).where(transcripts: { status: "completed" }).count
  end
end
