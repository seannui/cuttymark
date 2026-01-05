require "builder"

module Export
  class PremiereXmlExporter
    class Error < StandardError; end

    FRAME_RATE = 30
    TIMEBASE = 30

    def initialize
      @frame_rate = FRAME_RATE
      @timebase = TIMEBASE
    end

    def export_clips(clips, output_path: nil, sequence_name: nil)
      raise Error, "No clips provided" if clips.empty?

      output_path ||= default_output_path(sequence_name || "cuttymark_export")
      FileUtils.mkdir_p(File.dirname(output_path))

      xml = build_xml(clips, sequence_name || "Cuttymark Export")

      File.write(output_path, xml)
      Rails.logger.info("[PremiereXmlExporter] Exported #{clips.size} clips to #{output_path}")

      output_path
    end

    def export_clip(clip, output_path: nil)
      export_clips([clip], output_path: output_path, sequence_name: clip.title)
    end

    private

    def build_xml(clips, sequence_name)
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: "1.0", encoding: "UTF-8"

      xml.xmeml(version: "5") do
        xml.sequence do
          xml.name(sequence_name)
          xml.duration(calculate_total_duration(clips))
          xml.rate do
            xml.timebase(@timebase)
            xml.ntsc("FALSE")
          end

          xml.media do
            build_video_track(xml, clips)
            build_audio_track(xml, clips)
          end
        end
      end
    end

    def build_video_track(xml, clips)
      xml.video do
        xml.format do
          xml.samplecharacteristics do
            xml.width(1920)
            xml.height(1080)
            xml.pixelaspectratio("square")
            xml.rate do
              xml.timebase(@timebase)
              xml.ntsc("FALSE")
            end
          end
        end

        xml.track do
          timeline_position = 0

          clips.each_with_index do |clip, index|
            build_clip_item(xml, clip, index, timeline_position)
            timeline_position += frames_for_duration(clip.duration)
          end
        end
      end
    end

    def build_audio_track(xml, clips)
      xml.audio do
        xml.format do
          xml.samplecharacteristics do
            xml.samplerate(48000)
            xml.depth(16)
          end
        end

        xml.track do
          timeline_position = 0

          clips.each_with_index do |clip, index|
            build_audio_item(xml, clip, index, timeline_position)
            timeline_position += frames_for_duration(clip.duration)
          end
        end
      end
    end

    def build_clip_item(xml, clip, index, timeline_position)
      clip_frames = frames_for_duration(clip.duration)
      in_frames = frames_for_seconds(clip.start_time)
      out_frames = frames_for_seconds(clip.end_time)

      xml.clipitem(id: "clipitem-#{index + 1}") do
        xml.name(clip.title.presence || "Clip #{clip.id}")
        xml.duration(clip_frames)
        xml.rate do
          xml.timebase(@timebase)
          xml.ntsc("FALSE")
        end
        xml.start(timeline_position)
        xml.end(timeline_position + clip_frames)
        xml.in(in_frames)
        xml.out(out_frames)

        xml.file(id: "file-#{clip.video_id}") do
          xml.name(clip.video.filename)
          xml.pathurl(file_url(clip.source_path))
          xml.duration(frames_for_seconds(clip.video.duration_seconds || 0))
          xml.rate do
            xml.timebase(@timebase)
            xml.ntsc("FALSE")
          end
        end

        # Add markers if clip has notes
        if clip.notes.present?
          xml.marker do
            xml.name("Note")
            xml.comment(clip.notes)
            xml.in(0)
            xml.out(-1)
          end
        end
      end
    end

    def build_audio_item(xml, clip, index, timeline_position)
      clip_frames = frames_for_duration(clip.duration)
      in_frames = frames_for_seconds(clip.start_time)
      out_frames = frames_for_seconds(clip.end_time)

      xml.clipitem(id: "audio-clipitem-#{index + 1}") do
        xml.name(clip.title.presence || "Clip #{clip.id}")
        xml.duration(clip_frames)
        xml.rate do
          xml.timebase(@timebase)
          xml.ntsc("FALSE")
        end
        xml.start(timeline_position)
        xml.end(timeline_position + clip_frames)
        xml.in(in_frames)
        xml.out(out_frames)

        xml.file(id: "file-#{clip.video_id}")

        xml.sourcetrack do
          xml.mediatype("audio")
          xml.trackindex(1)
        end
      end
    end

    def calculate_total_duration(clips)
      clips.sum { |clip| frames_for_duration(clip.duration) }
    end

    def frames_for_duration(duration)
      (duration * @frame_rate).round
    end

    def frames_for_seconds(seconds)
      (seconds * @frame_rate).round
    end

    def file_url(path)
      "file://localhost#{path}"
    end

    def default_output_path(name)
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      filename = "#{name.parameterize}_#{timestamp}.xml"
      Rails.root.join("storage", "exports", filename).to_s
    end
  end
end
