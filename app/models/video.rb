class Video < ApplicationRecord
  belongs_to :project
  has_one :transcript, dependent: :destroy
  has_many :segments, through: :transcript
  has_many :clips, dependent: :destroy

  validates :source_path, presence: true, uniqueness: true
  validates :filename, presence: true
  validates :status, presence: true

  enum :status, {
    pending: "pending",
    importing: "importing",
    ready: "ready",
    transcribing: "transcribing",
    transcribed: "transcribed",
    error: "error"
  }, default: :pending

  SUPPORTED_FORMATS = %w[mp4 mov mkv m4v avi webm].freeze
  BRAW_FORMAT = "braw"

  scope :pending_transcription, -> { where(status: %w[ready]).where.missing(:transcript) }
  scope :with_transcripts, -> { joins(:transcript).where(transcripts: { status: "completed" }) }

  def braw?
    format&.downcase == BRAW_FORMAT
  end

  def supported_format?
    SUPPORTED_FORMATS.include?(format&.downcase)
  end

  def needs_proxy?
    braw? && proxy_path.blank?
  end

  def playable_path
    proxy_path.presence || source_path
  end

  def duration_formatted
    return nil unless duration_seconds

    hours = (duration_seconds / 3600).to_i
    minutes = ((duration_seconds % 3600) / 60).to_i
    seconds = (duration_seconds % 60).to_i

    if hours > 0
      Kernel.format("%<hours>d:%<minutes>02d:%<seconds>02d", hours: hours, minutes: minutes, seconds: seconds)
    else
      Kernel.format("%<minutes>d:%<seconds>02d", minutes: minutes, seconds: seconds)
    end
  end

  def file_size_formatted
    return nil unless file_size

    if file_size >= 1.gigabyte
      Kernel.format("%.2f GB", file_size / 1.gigabyte.to_f)
    elsif file_size >= 1.megabyte
      Kernel.format("%.1f MB", file_size / 1.megabyte.to_f)
    else
      Kernel.format("%.0f KB", file_size / 1.kilobyte.to_f)
    end
  end
end
