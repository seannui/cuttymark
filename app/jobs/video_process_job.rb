class VideoProcessJob < ApplicationJob
  queue_as :video_processing

  retry_on Transcription::BaseClient::ConnectionError, wait: 30.seconds, attempts: 3

  # Process a video through the full pipeline
  # Can handle three scenarios:
  # 1. New file import: source_path provided, imports then processes
  # 2. Pending video: video exists but needs transcription
  # 3. Failed video: video/transcript failed, needs retry
  #
  # @param video_id [Integer, nil] existing video ID
  # @param source_path [String, nil] path to import (for new files)
  # @param project_id [Integer, nil] project for new imports
  def perform(video_id: nil, source_path: nil, project_id: nil)
    if source_path.present?
      import_and_process(source_path, project_id)
    elsif video_id.present?
      process_existing(video_id)
    else
      raise ArgumentError, "Must provide either video_id or source_path"
    end
  end

  private

  def import_and_process(source_path, project_id)
    Rails.logger.info("[VideoProcessJob] Importing new file: #{source_path}")

    unless File.exist?(source_path)
      Rails.logger.error("[VideoProcessJob] File not found: #{source_path}")
      raise ArgumentError, "Source file not found: #{source_path}"
    end

    project = Project.find(project_id)
    video = Video.import!(source_path, project: project)

    Rails.logger.info("[VideoProcessJob] Imported as video #{video.id}, starting processing")
    transcript = video.process!

    Rails.logger.info("[VideoProcessJob] Completed: #{video.filename} - #{transcript.segments.count} segments")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[VideoProcessJob] Project not found: #{project_id}")
    raise e
  end

  def process_existing(video_id)
    video = Video.find(video_id)
    Rails.logger.info("[VideoProcessJob] Processing existing video: #{video.filename} (#{video.id})")

    # Determine if this is a retry (failed) or fresh processing (pending)
    if video.error? || video.transcript&.failed?
      Rails.logger.info("[VideoProcessJob] Retrying failed video #{video.id}")
      transcript = video.retry!
    elsif video.ready? && video.transcript.nil?
      Rails.logger.info("[VideoProcessJob] Processing pending video #{video.id}")
      transcript = video.process!
    elsif video.transcribed?
      Rails.logger.info("[VideoProcessJob] Video #{video.id} already transcribed, skipping")
      return
    else
      Rails.logger.warn("[VideoProcessJob] Video #{video.id} in unexpected state: #{video.state}")
      return
    end

    Rails.logger.info("[VideoProcessJob] Completed: #{video.filename} - #{transcript.segments.count} segments")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[VideoProcessJob] Video not found: #{video_id}")
    raise e
  rescue StandardError => e
    Rails.logger.error("[VideoProcessJob] Error processing video #{video_id}: #{e.message}")
    raise e
  end
end
