class HlsEncodeJob < ApplicationJob
  queue_as :video_processing

  def perform(video_id)
    video = Video.find(video_id)
    return if video.hls_state == "completed"

    video.update!(hls_state: "processing")
    VideoProcessing::HlsService.new(video).generate!
    video.update!(hls_state: "completed")
  rescue => e
    video&.update!(hls_state: "failed")
    Rails.logger.error("[HlsEncodeJob] Failed for video #{video_id}: #{e.message}")
    raise
  end
end
