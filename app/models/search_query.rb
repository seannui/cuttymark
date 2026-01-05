class SearchQuery < ApplicationRecord
  belongs_to :project
  has_many :matches, dependent: :destroy
  has_many :segments, through: :matches
  has_many :clips, through: :matches

  has_neighbors :query_embedding

  validates :query_text, presence: true
  validates :match_type, presence: true

  enum :match_type, {
    exact: "exact",
    fuzzy: "fuzzy",
    semantic: "semantic"
  }, default: :semantic

  scope :semantic, -> { where(match_type: "semantic") }
  scope :exact, -> { where(match_type: "exact") }
  scope :fuzzy, -> { where(match_type: "fuzzy") }

  def matches_count
    matches.count
  end

  def videos_with_matches
    Video.joins(transcript: { segments: :matches })
         .where(matches: { search_query_id: id })
         .distinct
  end
end
