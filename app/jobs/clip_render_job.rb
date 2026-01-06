class ClipRenderJob < ApplicationJob
  queue_as :default

  def perform(clip_id)
    clip = Clip.find(clip_id)

    Rails.logger.info("[ClipRenderJob] Starting render for clip: #{clip.id}")

    clip.start_render!

    begin
      ffmpeg = VideoProcessing::FfmpegClient.new

      # Generate output paths
      base_filename = generate_base_filename(clip)
      output_path = Rails.root.join("storage", "exports", "#{base_filename}.mp4").to_s
      thumbnail_path = Rails.root.join("storage", "exports", "#{base_filename}.png").to_s

      # Render the clip
      ffmpeg.render_clip(
        clip.source_path,
        output_path,
        start_time: clip.start_time,
        end_time: clip.end_time
      )

      # Generate thumbnail from beginning of clip
      ffmpeg.generate_thumbnail(
        clip.source_path,
        thumbnail_path,
        timestamp: clip.start_time
      )

      clip.finish_render!
      clip.update!(export_path: output_path, thumbnail_path: thumbnail_path)

      Rails.logger.info("[ClipRenderJob] Completed render for clip: #{clip.id} -> #{output_path}")
    rescue VideoProcessing::FfmpegClient::Error => e
      clip.fail!
      Rails.logger.error("[ClipRenderJob] Failed to render clip #{clip.id}: #{e.message}")
      raise e
    end
  end

  private

  def generate_base_filename(clip)
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    title_slug = clip.title.present? ? clip.title.parameterize : "clip"
    "#{title_slug}_#{clip.id}_#{timestamp}"
  end
end
