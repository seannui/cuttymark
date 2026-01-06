class Video < ApplicationRecord
  include AASM

  belongs_to :project
  has_one :transcript, dependent: :destroy
  has_many :segments, through: :transcript
  has_many :clips, dependent: :destroy

  validates :source_path, presence: true, uniqueness: true
  validates :filename, presence: true

  SUPPORTED_FORMATS = %w[mp4 mov mkv m4v avi webm].freeze
  BRAW_FORMAT = "braw"

  aasm column: :state do
    state :pending, initial: true
    state :importing
    state :ready
    state :transcribing
    state :transcribed
    state :error

    event :start_import do
      transitions from: :pending, to: :importing
    end

    event :finish_import do
      transitions from: :importing, to: :ready
    end

    event :start_transcription do
      transitions from: :ready, to: :transcribing
    end

    event :finish_transcription do
      transitions from: :transcribing, to: :transcribed
    end

    event :fail do
      transitions from: [:importing, :transcribing], to: :error
    end

    event :reset do
      transitions from: [:pending, :ready, :transcribing, :transcribed, :error], to: :ready
    end
  end

  scope :pending_transcription, -> { ready.where.missing(:transcript) }
  scope :with_transcripts, -> { joins(:transcript).where(transcripts: { state: "completed" }) }

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

  # Reset video to fresh state for reprocessing
  # Deletes transcript, cached audio files, and resets state
  # Returns hash with details of what was cleaned up
  def reset_for_reprocessing!
    result = { transcript_deleted: false, segments_deleted: 0, audio_files_deleted: [] }

    # Delete transcript and segments
    if transcript
      result[:segments_deleted] = transcript.segments.count
      transcript.destroy!
      reload  # Clear cached association
      result[:transcript_deleted] = true
    end

    # Delete cached audio files
    audio_cache_dir = Rails.root.join("storage", "audio_cache")
    [
      audio_cache_dir.join("video_#{id}.wav"),
      audio_cache_dir.join("video_#{id}_normalized.wav")
    ].each do |path|
      if File.exist?(path)
        File.delete(path)
        result[:audio_files_deleted] << File.basename(path)
      end
    end

    # Reset state using AASM event
    reset!

    result
  end

  # Process video: transcribe and generate embeddings
  # Returns the completed transcript
  # @param engine [Symbol] :whisper or :gemini (defaults to TRANSCRIPTION_ENGINE env var)
  def process!(engine: nil)
    transcript_result = Transcription::TranscriptionService.new.transcribe(self, engine: engine)
    Embeddings::EmbeddingService.new.generate_for_transcript(transcript_result)
    transcript_result.complete! if transcript_result.may_complete?
    finish_transcription! if may_finish_transcription?
    transcript_result
  end

  # Queue video for async reprocessing
  def queue_for_reprocessing!
    VideoReprocessJob.perform_later(id)
  end

  # Class methods for batch operations
  class << self
    def reset_all_for_reprocessing!(scope = all)
      results = { total: 0, segments_deleted: 0, audio_files_deleted: 0 }

      scope.find_each do |video|
        result = video.reset_for_reprocessing!
        results[:total] += 1
        results[:segments_deleted] += result[:segments_deleted]
        results[:audio_files_deleted] += result[:audio_files_deleted].size
        yield(video, result) if block_given?
      end

      results
    end

    def queue_all_for_reprocessing!(scope = all)
      count = 0
      scope.find_each do |video|
        video.queue_for_reprocessing!
        count += 1
        yield(video) if block_given?
      end
      count
    end
  end
end
