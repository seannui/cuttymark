module Export
  class EdlExporter
    class Error < StandardError; end

    # CMX 3600 EDL format
    # Standard frame rate for NTSC
    DEFAULT_FRAME_RATE = 30

    def initialize(frame_rate: DEFAULT_FRAME_RATE, drop_frame: false)
      @frame_rate = frame_rate
      @drop_frame = drop_frame
    end

    def export_clips(clips, output_path: nil, title: nil)
      raise Error, "No clips provided" if clips.empty?

      title ||= "CUTTYMARK_EXPORT"
      output_path ||= default_output_path(title)
      FileUtils.mkdir_p(File.dirname(output_path))

      edl_content = build_edl(clips, title)

      File.write(output_path, edl_content)
      Rails.logger.info("[EdlExporter] Exported #{clips.size} clips to #{output_path}")

      output_path
    end

    def export_clip(clip, output_path: nil)
      export_clips([clip], output_path: output_path, title: clip.title&.upcase&.gsub(/\s+/, "_"))
    end

    private

    def build_edl(clips, title)
      lines = []

      # Header
      lines << "TITLE: #{sanitize_title(title)}"
      lines << "FCM: #{@drop_frame ? 'DROP FRAME' : 'NON-DROP FRAME'}"
      lines << ""

      # Track entries
      timeline_position = 0.0

      clips.each_with_index do |clip, index|
        edit_number = format("%03d", index + 1)
        lines << build_edit_entry(clip, edit_number, timeline_position)

        # Add source file comment
        lines << "* FROM CLIP NAME: #{clip.video.filename}"

        # Add notes as comment if present
        if clip.notes.present?
          lines << "* COMMENT: #{clip.notes}"
        end

        # Add search query info if from match
        if clip.match&.search_query
          lines << "* SEARCH: #{clip.match.search_query.query_text}"
        end

        lines << ""
        timeline_position += clip.duration
      end

      lines.join("\n")
    end

    def build_edit_entry(clip, edit_number, timeline_position)
      # CMX 3600 format:
      # EDIT# REEL TRACK TRANS SOURCE_IN SOURCE_OUT REC_IN REC_OUT

      reel = generate_reel_name(clip.video)
      track = "V"  # Video track
      transition = "C"  # Cut

      source_in = seconds_to_timecode(clip.start_time)
      source_out = seconds_to_timecode(clip.end_time)
      rec_in = seconds_to_timecode(timeline_position)
      rec_out = seconds_to_timecode(timeline_position + clip.duration)

      # Standard CMX 3600 line format (fixed width columns)
      "#{edit_number}  #{reel.ljust(8)} #{track.ljust(6)} #{transition}        #{source_in} #{source_out} #{rec_in} #{rec_out}"
    end

    def seconds_to_timecode(seconds)
      return "00:00:00:00" if seconds.nil? || seconds < 0

      total_frames = (seconds * @frame_rate).round

      frames = total_frames % @frame_rate
      total_seconds = total_frames / @frame_rate
      secs = total_seconds % 60
      total_minutes = total_seconds / 60
      mins = total_minutes % 60
      hours = total_minutes / 60

      separator = @drop_frame ? ";" : ":"

      format("%02d:%02d:%02d%s%02d", hours, mins, secs, separator, frames)
    end

    def generate_reel_name(video)
      # EDL reel names are typically 8 characters max
      # Use video ID padded, or truncated filename
      base = video.filename.gsub(/\.[^.]+$/, "")  # Remove extension
      base = base.gsub(/[^A-Za-z0-9]/, "")        # Remove special chars
      base = base.upcase

      if base.length > 8
        "#{base[0, 6]}#{format('%02d', video.id % 100)}"
      elsif base.length < 8
        base.ljust(8, "0")
      else
        base
      end
    end

    def sanitize_title(title)
      # EDL titles should be uppercase, no special characters
      title.upcase.gsub(/[^A-Z0-9_\s]/, "").gsub(/\s+/, "_")[0, 32]
    end

    def default_output_path(title)
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      filename = "#{sanitize_title(title).downcase}_#{timestamp}.edl"
      Rails.root.join("storage", "exports", filename).to_s
    end
  end
end
