class Clip < ApplicationRecord
  include AASM

  belongs_to :video
  belongs_to :match, optional: true

  validates :start_time, presence: true
  validates :end_time, presence: true
  validate :end_time_after_start_time

  aasm column: :state do
    state :defined, initial: true
    state :rendering
    state :rendered
    state :failed

    event :start_render do
      transitions from: :defined, to: :rendering
    end

    event :finish_render do
      transitions from: :rendering, to: :rendered
    end

    event :fail do
      transitions from: [:defined, :rendering], to: :failed
    end

    event :reset do
      transitions from: [:rendered, :failed], to: :defined
    end
  end

  scope :ordered, -> { order(:start_time) }

  delegate :project, to: :video

  def duration
    end_time - start_time
  end

  def duration_formatted
    seconds = duration
    mins = (seconds / 60).to_i
    secs = (seconds % 60).round(1)

    if mins > 0
      format("%<mins>d:%<secs>05.2f", mins: mins, secs: secs)
    else
      format("%.1fs", secs)
    end
  end

  def time_range_formatted
    format_time(start_time) + " - " + format_time(end_time)
  end

  def display_title
    title.presence || "Clip #{id} (#{time_range_formatted})"
  end

  def source_path
    video.playable_path
  end

  private

  def format_time(seconds)
    hours = (seconds / 3600).to_i
    mins = ((seconds % 3600) / 60).to_i
    secs = (seconds % 60).round(1)

    if hours > 0
      format("%<hours>d:%<mins>02d:%<secs>05.2f", hours: hours, mins: mins, secs: secs)
    else
      format("%<mins>d:%<secs>05.2f", mins: mins, secs: secs)
    end
  end

  def end_time_after_start_time
    return unless start_time && end_time

    if end_time <= start_time
      errors.add(:end_time, "must be after start time")
    end
  end
end
