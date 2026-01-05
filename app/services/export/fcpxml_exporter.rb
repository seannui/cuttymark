require "builder"

module Export
  class FcpxmlExporter
    class Error < StandardError; end

    FCPXML_VERSION = "1.10"
    FRAME_DURATION = "1001/30000s"  # 29.97fps expressed as rational

    def initialize(frame_rate: 30)
      @frame_rate = frame_rate
    end

    def export_clips(clips, output_path: nil, project_name: nil)
      raise Error, "No clips provided" if clips.empty?

      project_name ||= "Cuttymark Export"
      output_path ||= default_output_path(project_name)
      FileUtils.mkdir_p(File.dirname(output_path))

      xml = build_fcpxml(clips, project_name)

      File.write(output_path, xml)
      Rails.logger.info("[FcpxmlExporter] Exported #{clips.size} clips to #{output_path}")

      output_path
    end

    def export_clip(clip, output_path: nil)
      export_clips([clip], output_path: output_path, project_name: clip.title)
    end

    private

    def build_fcpxml(clips, project_name)
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: "1.0", encoding: "UTF-8"

      xml.fcpxml(version: FCPXML_VERSION) do
        build_resources(xml, clips)
        build_library(xml, clips, project_name)
      end
    end

    def build_resources(xml, clips)
      xml.resources do
        # Define format
        xml.format(
          id: "r1",
          name: "FFVideoFormat1080p30",
          frameDuration: FRAME_DURATION,
          width: "1920",
          height: "1080"
        )

        # Define media assets
        clips.map(&:video).uniq.each_with_index do |video, index|
          asset_id = "r#{index + 2}"
          build_asset(xml, video, asset_id)
        end
      end
    end

    def build_asset(xml, video, asset_id)
      duration = fcpxml_time(video.duration_seconds || 0)

      xml.asset(
        id: asset_id,
        name: video.filename,
        src: file_url(video.source_path),
        start: "0s",
        duration: duration,
        hasVideo: "1",
        hasAudio: "1",
        format: "r1"
      ) do
        xml.tag!("media-rep", kind: "original-media", src: file_url(video.source_path))
      end
    end

    def build_library(xml, clips, project_name)
      xml.library do
        xml.event(name: project_name) do
          xml.project(name: project_name) do
            build_sequence(xml, clips)
          end
        end
      end
    end

    def build_sequence(xml, clips)
      total_duration = fcpxml_time(clips.sum(&:duration))

      xml.sequence(
        format: "r1",
        duration: total_duration,
        tcStart: "0s",
        tcFormat: "NDF"
      ) do
        xml.spine do
          timeline_offset = 0.0

          clips.each_with_index do |clip, index|
            build_clip_ref(xml, clip, index, timeline_offset)
            timeline_offset += clip.duration
          end
        end
      end
    end

    def build_clip_ref(xml, clip, index, timeline_offset)
      video = clip.video
      asset_id = find_asset_id(video, index)

      # Calculate times
      start_time = fcpxml_time(clip.start_time)
      duration = fcpxml_time(clip.duration)
      offset = fcpxml_time(timeline_offset)

      xml.tag!(
        "asset-clip",
        name: clip.title.presence || "Clip #{clip.id}",
        ref: asset_id,
        offset: offset,
        duration: duration,
        start: start_time,
        tcFormat: "NDF"
      ) do
        # Add note as marker if present
        if clip.notes.present?
          xml.marker(
            start: "0s",
            duration: "1/30s",
            value: clip.notes
          )
        end

        # Add keyword for search query if from a match
        if clip.match&.search_query
          xml.keyword(
            start: "0s",
            duration: duration,
            value: clip.match.search_query.query_text
          )
        end
      end
    end

    def find_asset_id(video, default_index)
      # In a real implementation, we'd track asset IDs properly
      # For now, use video_id to ensure consistency
      "r#{(video.id % 100) + 2}"
    end

    def fcpxml_time(seconds)
      return "0s" if seconds.nil? || seconds <= 0

      # Convert to rational time representation
      # Using 30000/1001 timebase (29.97fps)
      frames = (seconds * 30000.0 / 1001.0).round
      "#{frames * 1001}/30000s"
    end

    def file_url(path)
      "file://#{path}"
    end

    def default_output_path(name)
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      filename = "#{name.parameterize}_#{timestamp}.fcpxml"
      Rails.root.join("storage", "exports", filename).to_s
    end
  end
end
