require "test_helper"

class Export::FcpxmlExporterTest < ActiveSupport::TestCase
  setup do
    @exporter = Export::FcpxmlExporter.new
    @clip = clips(:rob_reiner_clip)
    @output_dir = Rails.root.join("tmp", "test_exports")
    FileUtils.mkdir_p(@output_dir)
  end

  teardown do
    FileUtils.rm_rf(@output_dir)
  end

  test "exports single clip to FCPXML" do
    output_path = File.join(@output_dir, "test.fcpxml")
    result = @exporter.export_clip(@clip, output_path: output_path)

    assert File.exist?(result)
    content = File.read(result)

    assert_match(/<\?xml version="1.0"/, content)
    assert_match(/<fcpxml version="1.10">/, content)
    assert_match(/<resources>/, content)
    assert_match(/<library>/, content)
  end

  test "exports multiple clips to FCPXML" do
    clips = [clips(:rob_reiner_clip), clips(:river_phoenix_clip)]
    output_path = File.join(@output_dir, "batch.fcpxml")

    result = @exporter.export_clips(clips, output_path: output_path, project_name: "Test Project")

    assert File.exist?(result)
    content = File.read(result)

    assert_match(/<event name="Test Project">/, content)
    assert_match(/<project name="Test Project">/, content)
    assert_match(/<spine>/, content)
  end

  test "includes format definition" do
    output_path = File.join(@output_dir, "test.fcpxml")
    @exporter.export_clip(@clip, output_path: output_path)

    content = File.read(output_path)

    assert_match(/<format id="r1"/, content)
    assert_match(/frameDuration="1001\/30000s"/, content)
  end

  test "includes asset definitions" do
    output_path = File.join(@output_dir, "test.fcpxml")
    @exporter.export_clip(@clip, output_path: output_path)

    content = File.read(output_path)

    assert_match(/<asset id="r\d+"/, content)
    assert_match(/hasVideo="1"/, content)
    assert_match(/hasAudio="1"/, content)
  end

  test "converts seconds to fcpxml time format" do
    time = @exporter.send(:fcpxml_time, 10.0)

    # 10 seconds at 29.97fps = ~300 frames
    assert_match(/\d+\/30000s$/, time)
  end

  test "raises error for empty clips" do
    assert_raises Export::FcpxmlExporter::Error do
      @exporter.export_clips([])
    end
  end
end
