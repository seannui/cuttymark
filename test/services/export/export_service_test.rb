require "test_helper"

class Export::ExportServiceTest < ActiveSupport::TestCase
  setup do
    @service = Export::ExportService.new
    @clip = clips(:rob_reiner_clip)
    @output_dir = Rails.root.join("tmp", "test_exports")
    FileUtils.mkdir_p(@output_dir)
  end

  teardown do
    FileUtils.rm_rf(@output_dir)
  end

  test "available_formats returns all formats" do
    formats = @service.available_formats

    assert formats.key?(:mp4_copy)
    assert formats.key?(:premiere_xml)
    assert formats.key?(:fcpxml)
    assert formats.key?(:edl)
  end

  test "video_formats returns only video formats" do
    formats = @service.video_formats

    assert formats.key?(:mp4_copy)
    assert formats.key?(:prores_422)
    refute formats.key?(:premiere_xml)
    refute formats.key?(:fcpxml)
  end

  test "edit_list_formats returns only edit list formats" do
    formats = @service.edit_list_formats

    assert formats.key?(:premiere_xml)
    assert formats.key?(:fcpxml)
    assert formats.key?(:edl)
    refute formats.key?(:mp4_copy)
  end

  test "exports to premiere_xml format" do
    result = @service.export(@clip, format: :premiere_xml, name: "Test")

    assert File.exist?(result)
    assert result.end_with?(".xml")
  end

  test "exports to fcpxml format" do
    result = @service.export(@clip, format: :fcpxml, name: "Test")

    assert File.exist?(result)
    assert result.end_with?(".fcpxml")
  end

  test "exports to edl format" do
    result = @service.export(@clip, format: :edl, name: "Test")

    assert File.exist?(result)
    assert result.end_with?(".edl")
  end

  test "raises error for unknown format" do
    assert_raises Export::ExportService::Error do
      @service.export(@clip, format: :unknown_format)
    end
  end

  test "raises error for empty clips" do
    assert_raises Export::ExportService::Error do
      @service.export([], format: :edl)
    end
  end

  test "export_batch exports to multiple formats" do
    clips = [clips(:rob_reiner_clip), clips(:river_phoenix_clip)]
    formats = [:premiere_xml, :fcpxml, :edl]

    results = @service.export_batch(clips, formats: formats, name: "Batch Test")

    assert_equal 3, results[:success].size
    assert_empty results[:failed]
  end
end
