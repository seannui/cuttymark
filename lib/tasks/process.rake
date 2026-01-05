namespace :cuttymark do
  desc "Process a video file through the full pipeline: import, transcribe, embed"
  task :process, [:source_path, :project_name] => :environment do |_t, args|
    source_path = args[:source_path]
    project_name = args[:project_name] || "Default Project"

    abort "Usage: rake cuttymark:process[/path/to/video.mp4]" if source_path.blank?
    abort "File not found: #{source_path}" unless File.exist?(source_path)

    puts "=" * 60
    puts "Cuttymark Video Processing Pipeline"
    puts "=" * 60
    puts ""

    check_dependencies!

    project = Project.find_or_create_by!(name: project_name) do |p|
      p.description = "Created by cuttymark:process task"
    end

    process_video(source_path, project)
  end

  desc "Process all unprocessed video files in storage/sources"
  task :process_all, [:project_name] => :environment do |_t, args|
    project_name = args[:project_name] || "Default Project"

    puts "=" * 60
    puts "Cuttymark Batch Processing"
    puts "=" * 60
    puts ""

    check_dependencies!

    project = Project.find_or_create_by!(name: project_name) do |p|
      p.description = "Created by cuttymark:process_all task"
    end
    puts "Project: #{project.name} (ID: #{project.id})"
    puts ""

    # Scan for unprocessed files
    sources_dir = Rails.root.join("storage", "sources")
    unless Dir.exist?(sources_dir)
      abort "Sources directory not found: #{sources_dir}"
    end

    imported_paths = Video.pluck(:source_path).compact.to_set
    extensions = Video::SUPPORTED_FORMATS + [Video::BRAW_FORMAT]
    pattern = File.join(sources_dir, "**", "*.{#{extensions.join(',')}}")

    all_files = Dir.glob(pattern, File::FNM_CASEFOLD).sort
    unprocessed = all_files.reject { |path| imported_paths.include?(path) }

    if unprocessed.empty?
      puts "No unprocessed files found in #{sources_dir}"
      puts ""
      puts "Already imported: #{imported_paths.size} videos"
      exit 0
    end

    puts "Found #{unprocessed.size} unprocessed file(s):"
    unprocessed.each_with_index do |path, i|
      relative = Pathname.new(path).relative_path_from(sources_dir)
      size = number_to_human_size(File.size(path))
      puts "  #{i + 1}. #{relative} (#{size})"
    end
    puts ""

    # Process each file
    successful = 0
    failed = []

    unprocessed.each_with_index do |source_path, index|
      relative = Pathname.new(source_path).relative_path_from(sources_dir)
      puts "=" * 60
      puts "[#{index + 1}/#{unprocessed.size}] Processing: #{relative}"
      puts "=" * 60
      puts ""

      begin
        process_video(source_path, project)
        successful += 1
      rescue StandardError => e
        puts ""
        puts "ERROR: #{e.message}"
        puts ""
        failed << { path: source_path, error: e.message }
      end

      puts ""
    end

    # Final summary
    puts "=" * 60
    puts "Batch Processing Complete"
    puts "=" * 60
    puts ""
    puts "Successful: #{successful}/#{unprocessed.size}"

    if failed.any?
      puts "Failed: #{failed.size}"
      failed.each do |f|
        relative = Pathname.new(f[:path]).relative_path_from(sources_dir)
        puts "  - #{relative}: #{f[:error]}"
      end
    end
    puts ""
  end

  def check_dependencies!
    print "Checking Whisper server... "
    whisper = Transcription::WhisperClient.new
    unless whisper.health_check
      abort "FAILED\n\nWhisper server is not available at #{whisper.instance_variable_get(:@host)}:#{whisper.instance_variable_get(:@port)}"
    end
    puts "OK"

    print "Checking Ollama server... "
    ollama = Embeddings::OllamaClient.new
    unless ollama.health_check
      abort "FAILED\n\nOllama server is not available. Run: ollama serve"
    end
    puts "OK"

    print "Checking FFmpeg... "
    ffmpeg = VideoProcessing::FfmpegClient.new
    unless ffmpeg.available?
      abort "FAILED\n\nFFmpeg not found. Run: brew install ffmpeg"
    end
    puts "OK (#{ffmpeg.version})"
    puts ""
  end

  def process_video(source_path, project)
    puts "Source: #{source_path}"
    puts "Project: #{project.name}"
    puts ""

    # Step 1: Import
    puts "-" * 60
    puts "Step 1: Importing video"
    puts "-" * 60

    import_service = VideoProcessing::ImportService.new
    video = import_service.import(source_path, project: project)
    puts "Video imported: #{video.filename} (ID: #{video.id})"
    puts "  Duration: #{format_duration(video.duration_seconds)}"
    puts "  Format: #{video.format}"
    puts "  Size: #{number_to_human_size(video.file_size)}"
    puts ""

    # Step 2: Transcribe
    puts "-" * 60
    puts "Step 2: Transcribing with Whisper"
    puts "-" * 60

    transcription_service = Transcription::TranscriptionService.new
    start_time = Time.current

    puts "Transcribing (this may take a while for long videos)..."
    transcript = transcription_service.transcribe(video)

    elapsed = Time.current - start_time
    puts ""
    puts "Transcription complete in #{format_duration(elapsed)}"
    puts "  Words: #{transcript.segments.words.count}"
    puts "  Sentences: #{transcript.segments.sentences.count}"
    puts "  Paragraphs: #{transcript.segments.paragraphs.count}"
    puts ""

    # Step 3: Generate embeddings
    puts "-" * 60
    puts "Step 3: Generating embeddings with Ollama"
    puts "-" * 60

    ollama = Embeddings::OllamaClient.new
    segments = transcript.sentence_segments.where(embedding: nil)
    total = segments.count

    puts "Processing #{total} sentence segments..."
    start_time = Time.current

    segments.find_each.with_index do |segment, index|
      embedding = ollama.embed(segment.text)
      segment.update!(embedding: embedding) if embedding

      # Progress indicator
      progress = ((index + 1).to_f / total * 100).round(1)
      print "\r  Progress: #{index + 1}/#{total} (#{progress}%)"
    end
    puts ""

    transcript.update!(status: :completed)
    elapsed = Time.current - start_time
    puts "Embeddings complete in #{format_duration(elapsed)}"
    puts ""

    # Summary
    puts "-" * 60
    puts "Video Complete: #{video.filename}"
    puts "-" * 60
    puts "  Video ID: #{video.id}"
    puts "  Transcript ID: #{transcript.id}"
    puts "  Words: #{transcript.segments.words.count}"
    puts "  Sentences: #{transcript.segments.sentences.count}"
    puts "  Web UI: http://localhost:3000/videos/#{video.id}"
    puts ""
  end

  desc "Search a video transcript for a phrase"
  task :search, [:video_id, :query] => :environment do |_t, args|
    video_id = args[:video_id]
    query = args[:query]

    abort "Usage: rake cuttymark:search[VIDEO_ID,'search query']" if video_id.blank? || query.blank?

    video = Video.find(video_id)
    transcript = video.transcript

    abort "Video has no transcript" unless transcript

    puts "Searching '#{query}' in #{video.filename}..."
    puts ""

    # Create search query
    search_query = SearchQuery.create!(
      project: video.project,
      query_text: query,
      match_type: :semantic
    )

    # Generate embedding for query
    embedding_service = Embeddings::EmbeddingService.new
    embedding_service.generate_for_query(search_query)

    # Perform search
    search_service = Search::SemanticSearch.new
    matches = search_service.search(search_query, limit: 10)

    if matches.empty?
      puts "No matches found."
    else
      puts "Found #{matches.size} matches:"
      puts ""

      matches.each_with_index do |match, index|
        segment = match.segment
        puts "#{index + 1}. [#{format_timestamp(segment.start_time)} - #{format_timestamp(segment.end_time)}]"
        puts "   Score: #{(match.relevance_score * 100).round(1)}%"
        puts "   \"#{segment.text.truncate(100)}\""
        puts ""
      end
    end
  end

  private

  def format_duration(seconds)
    return "0s" unless seconds

    hours = (seconds / 3600).to_i
    minutes = ((seconds % 3600) / 60).to_i
    secs = (seconds % 60).to_i

    if hours > 0
      "#{hours}h #{minutes}m #{secs}s"
    elsif minutes > 0
      "#{minutes}m #{secs}s"
    else
      "#{secs}s"
    end
  end

  def format_timestamp(seconds)
    return "00:00" unless seconds

    hours = (seconds / 3600).to_i
    minutes = ((seconds % 3600) / 60).to_i
    secs = (seconds % 60).to_i

    if hours > 0
      format("%d:%02d:%02d", hours, minutes, secs)
    else
      format("%d:%02d", minutes, secs)
    end
  end

  def number_to_human_size(bytes)
    return "0 B" unless bytes

    units = %w[B KB MB GB TB]
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = units.size - 1 if exp > units.size - 1

    "%.1f %s" % [bytes.to_f / 1024**exp, units[exp]]
  end
end
