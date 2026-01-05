require "test_helper"

class Export::PremiereXmlExporterTest < ActiveSupport::TestCase
  setup do
    @exporter = Export::PremiereXmlExporter.new
    @clip = clips(:rob_reiner_clip)
    @output_dir = Rails.root.join("tmp", "test_exports")
    FileUtils.mkdir_p(@output_dir)
  end

  teardown do
    FileUtils.rm_rf(@output_dir)
  end

  test "exports single clip to Premiere XML" do
    output_path = File.join(@output_dir, "test.xml")
    result = @exporter.export_clip(@clip, output_path: output_path)

    assert File.exist?(result)
    content = File.read(result)

    assert_match(/<\?xml version="1.0"/, content)
    assert_match(/<xmeml version="5">/, content)
    assert_match(/<sequence>/, content)
    assert_match(/<video>/, content)
    assert_match(/<audio>/, content)
  end

  test "exports multiple clips to Premiere XML" do
    clips = [clips(:rob_reiner_clip), clips(:river_phoenix_clip)]
    output_path = File.join(@output_dir, "batch.xml")

    result = @exporter.export_clips(clips, output_path: output_path, sequence_name: "Test Sequence")

    assert File.exist?(result)
    content = File.read(result)

    assert_match(/<name>Test Sequence<\/name>/, content)
    assert_match(/clipitem-1/, content)
    assert_match(/clipitem-2/, content)
  end

  test "includes file references" do
    output_path = File.join(@output_dir, "test.xml")
    @exporter.export_clip(@clip, output_path: output_path)

    content = File.read(output_path)

    assert_match(/<file id="file-/, content)
    assert_match(/<pathurl>file:\/\/localhost/, content)
    assert_match(/reunion\.mp4/, content)
  end

  test "includes markers for clips with notes" do
    output_path = File.join(@output_dir, "test.xml")
    @exporter.export_clip(@clip, output_path: output_path)

    content = File.read(output_path)

    assert_match(/<marker>/, content)
    assert_match(/<comment>/, content)
  end

  test "raises error for empty clips" do
    assert_raises Export::PremiereXmlExporter::Error do
      @exporter.export_clips([])
    end
  end

  test "calculates correct frame duration" do
    frames = @exporter.send(:frames_for_duration, @clip.duration)

    expected_frames = (@clip.duration * 30).round
    assert_equal expected_frames, frames
  end
end
