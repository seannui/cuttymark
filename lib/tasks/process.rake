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

  desc "Process all unprocessed video files in storage/sources (includes retrying failed)"
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

    sources_dir = Rails.root.join("storage", "sources")
    unless Dir.exist?(sources_dir)
      abort "Sources directory not found: #{sources_dir}"
    end

    # Find videos that need processing:
    # 1. New files not yet imported
    # 2. Videos with error status
    # 3. Videos with failed transcripts

    # Get all imported videos
    imported_videos = Video.all.index_by(&:source_path)
    imported_paths = imported_videos.keys.to_set

    # Find failed videos that need retry (use separate queries due to Rails OR limitations)
    error_videos = Video.error.to_a
    failed_transcript_videos = Video.joins(:transcript).merge(Transcript.failed).to_a
    failed_videos = (error_videos + failed_transcript_videos).uniq(&:id)

    extensions = Video::SUPPORTED_FORMATS + [Video::BRAW_FORMAT]
    pattern = File.join(sources_dir, "**", "*.{#{extensions.join(',')}}")

    all_files = Dir.glob(pattern, File::FNM_CASEFOLD).sort
    new_files = all_files.reject { |path| imported_paths.include?(path) }

    # Report what we found
    puts "Status:"
    puts "  New files to import: #{new_files.size}"
    puts "  Failed videos to retry: #{failed_videos.size}"
    puts ""

    if new_files.empty? && failed_videos.empty?
      puts "Nothing to process!"
      puts "  Already processed: #{imported_paths.size} videos"
      exit 0
    end

    # Show new files
    if new_files.any?
      puts "New file(s) to process:"
      new_files.each_with_index do |path, i|
        relative = Pathname.new(path).relative_path_from(sources_dir)
        size = number_to_human_size(File.size(path))
        puts "  #{i + 1}. #{relative} (#{size})"
      end
      puts ""
    end

    # Show failed videos to retry
    if failed_videos.any?
      puts "Failed video(s) to retry:"
      failed_videos.each_with_index do |video, i|
        error_msg = video.transcript&.error_message || "Unknown error"
        puts "  #{i + 1}. #{video.filename} (ID: #{video.id})"
        puts "     Previous error: #{error_msg.truncate(80)}"
      end
      puts ""
    end

    # Process everything
    successful = 0
    failed = []
    total = new_files.size + failed_videos.size
    current = 0

    # Process new files
    new_files.each do |source_path|
      current += 1
      relative = Pathname.new(source_path).relative_path_from(sources_dir)
      puts "=" * 60
      puts "[#{current}/#{total}] Processing NEW: #{relative}"
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

    # Retry failed videos
    failed_videos.each do |video|
      current += 1
      puts "=" * 60
      puts "[#{current}/#{total}] RETRYING: #{video.filename} (ID: #{video.id})"
      puts "=" * 60
      puts ""

      begin
        retry_video(video)
        successful += 1
      rescue StandardError => e
        puts ""
        puts "ERROR: #{e.message}"
        puts ""
        failed << { path: video.source_path, error: e.message }
      end

      puts ""
    end

    # Final summary
    puts "=" * 60
    puts "Batch Processing Complete"
    puts "=" * 60
    puts ""
    puts "Successful: #{successful}/#{total}"

    if failed.any?
      puts "Failed: #{failed.size}"
      failed.each do |f|
        puts "  - #{File.basename(f[:path])}: #{f[:error].truncate(60)}"
      end
    end
    puts ""
  end

  desc "Retry a specific failed video"
  task :retry, [:video_id] => :environment do |_t, args|
    video_id = args[:video_id]
    abort "Usage: rake cuttymark:retry[VIDEO_ID]" if video_id.blank?

    check_dependencies!

    video = Video.find(video_id)
    puts "Retrying transcription for: #{video.filename} (ID: #{video.id})"
    puts ""

    retry_video(video)
  end

  desc "Reprocess all videos from scratch (re-transcribe and re-embed with current settings)"
  task :reprocess_all, [:project_name] => :environment do |_t, args|
    project_name = args[:project_name]

    puts "=" * 60
    puts "Cuttymark Full Reprocessing (Parallel)"
    puts "=" * 60
    puts ""

    check_dependencies!

    # Find videos to reprocess
    scope = if project_name.present?
              project = Project.find_by!(name: project_name)
              puts "Project: #{project.name} (ID: #{project.id})"
              project.videos.order(:id)
            else
              puts "Project: ALL"
              Video.order(:id)
            end

    if scope.empty?
      puts "\nNo videos found to reprocess."
      exit 0
    end

    puts "\nFound #{scope.count} video(s) to reprocess.\n\n"

    # Step 1: Reset all videos
    puts "-" * 60
    puts "Step 1: Resetting all videos to fresh state"
    puts "-" * 60
    puts ""

    totals = Video.reset_all_for_reprocessing!(scope) do |video, result|
      parts = ["  #{video.filename} (ID: #{video.id})"]
      parts << "#{result[:segments_deleted]} segments" if result[:transcript_deleted]
      parts << result[:audio_files_deleted].join(", ") if result[:audio_files_deleted].any?
      puts parts.join(" - ")
    end

    puts "\nReset: #{totals[:segments_deleted]} segments, #{totals[:audio_files_deleted]} audio files\n\n"

    # Step 2: Queue jobs
    puts "-" * 60
    puts "Step 2: Queueing reprocessing jobs"
    puts "-" * 60
    puts ""

    count = Video.queue_all_for_reprocessing!(scope) do |video|
      puts "  Queued: #{video.filename} (ID: #{video.id})"
    end

    puts "\n" + "=" * 60
    puts "#{count} Videos Queued for Reprocessing"
    puts "=" * 60
    puts "\nMonitor: http://localhost:3000/jobs"
    puts ""
  end

  desc "Wait for all video processing jobs to complete"
  task :wait_for_jobs => :environment do
    puts "Waiting for video processing jobs to complete..."
    puts "Press Ctrl+C to stop waiting (jobs will continue in background)"
    puts ""

    loop do
      # Count pending/running jobs in video_processing queue
      pending = SolidQueue::Job.where(queue_name: "video_processing")
                               .where.not(finished_at: nil)
                               .or(SolidQueue::Job.where(queue_name: "video_processing", finished_at: nil))
                               .where(finished_at: nil)
                               .count

      # Get recently completed
      completed = Video.transcribed.count
      failed = Video.error.count
      processing = Video.transcribing.count + Video.ready.joins(:transcript).merge(Transcript.processing).count

      print "\r  Pending: #{pending} | Processing: #{processing} | Completed: #{completed} | Failed: #{failed}    "

      break if pending == 0 && processing == 0

      sleep 2
    end

    puts ""
    puts ""
    puts "All jobs completed!"
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

    transcript.complete!
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

  def retry_video(video)
    puts "Source: #{video.source_path}"
    puts "Previous state: #{video.aasm.current_state}"
    if video.transcript
      puts "Previous transcript state: #{video.transcript.aasm.current_state}"
      puts "Previous error: #{video.transcript.error_message}" if video.transcript.error_message.present?
    end
    puts ""

    # Reset video state
    puts "-" * 60
    puts "Step 1: Resetting video state"
    puts "-" * 60

    # Use the model method to reset
    result = video.reset_for_reprocessing!
    puts "Deleted previous transcript" if result[:transcript_deleted]
    result[:audio_files_deleted].each { |f| puts "Deleted: #{f}" }
    puts "Video state reset to: ready"
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

    transcript.complete!
    elapsed = Time.current - start_time
    puts "Embeddings complete in #{format_duration(elapsed)}"
    puts ""

    # Summary
    puts "-" * 60
    puts "Video Retry Complete: #{video.filename}"
    puts "-" * 60
    puts "  Video ID: #{video.id}"
    puts "  Transcript ID: #{transcript.id}"
    puts "  Words: #{transcript.segments.words.count}"
    puts "  Sentences: #{transcript.segments.sentences.count}"
    puts "  Web UI: http://localhost:3000/videos/#{video.id}"
    puts ""
  end

  def reprocess_video(video)
    puts "Source: #{video.source_path}"
    puts "Current state: #{video.aasm.current_state}"
    if video.transcript
      puts "Current transcript: #{video.transcript.segments.count} segments"
    end
    puts ""

    # Step 1: Clean up existing data
    puts "-" * 60
    puts "Step 1: Cleaning up existing data"
    puts "-" * 60

    # Use the model method to reset
    result = video.reset_for_reprocessing!
    puts "Deleted transcript with #{result[:segments_deleted]} segments" if result[:transcript_deleted]
    result[:audio_files_deleted].each { |f| puts "Deleted: #{f}" }
    puts "Video state reset to: ready"
    puts ""

    # Step 2: Transcribe with normalization
    puts "-" * 60
    puts "Step 2: Transcribing with Whisper (with audio normalization)"
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

    transcript.complete!
    elapsed = Time.current - start_time
    puts "Embeddings complete in #{format_duration(elapsed)}"
    puts ""

    # Summary
    puts "-" * 60
    puts "Reprocess Complete: #{video.filename}"
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
