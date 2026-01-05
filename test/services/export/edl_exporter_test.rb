require "test_helper"

class Export::EdlExporterTest < ActiveSupport::TestCase
  setup do
    @exporter = Export::EdlExporter.new
    @clip = clips(:rob_reiner_clip)
    @output_dir = Rails.root.join("tmp", "test_exports")
    FileUtils.mkdir_p(@output_dir)
  end

  teardown do
    FileUtils.rm_rf(@output_dir)
  end

  test "exports single clip to EDL format" do
    output_path = File.join(@output_dir, "test.edl")
    result = @exporter.export_clip(@clip, output_path: output_path)

    assert File.exist?(result)
    content = File.read(result)

    assert_match(/TITLE:/, content)
    assert_match(/FCM: NON-DROP FRAME/, content)
    assert_match(/001/, content)  # First edit number
    assert_match(/FROM CLIP NAME:/, content)
  end

  test "exports multiple clips to EDL format" do
    clips = [clips(:rob_reiner_clip), clips(:river_phoenix_clip)]
    output_path = File.join(@output_dir, "batch.edl")

    result = @exporter.export_clips(clips, output_path: output_path, title: "Test Sequence")

    assert File.exist?(result)
    content = File.read(result)

    assert_match(/TITLE: TEST_SEQUENCE/, content)
    assert_match(/001/, content)
    assert_match(/002/, content)
  end

  test "converts seconds to timecode correctly" do
    exporter = Export::EdlExporter.new(frame_rate: 30)

    # Access private method for testing
    timecode = exporter.send(:seconds_to_timecode, 3661.5)  # 1:01:01:15 at 30fps

    assert_equal "01:01:01:15", timecode
  end

  test "generates valid reel names" do
    video = videos(:reunion_video)
    reel = @exporter.send(:generate_reel_name, video)

    assert reel.length <= 8
    assert_match(/^[A-Z0-9]+$/, reel)
  end

  test "raises error for empty clips" do
    assert_raises Export::EdlExporter::Error do
      @exporter.export_clips([])
    end
  end

  test "handles drop frame timecode" do
    exporter = Export::EdlExporter.new(frame_rate: 30, drop_frame: true)
    output_path = File.join(@output_dir, "drop_frame.edl")

    result = exporter.export_clip(@clip, output_path: output_path)
    content = File.read(result)

    assert_match(/FCM: DROP FRAME/, content)
  end
end
