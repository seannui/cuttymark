namespace :cm do
  namespace :jobs do
    desc "Show job queue status"
    task status: :environment do
      pending = SolidQueue::Job.where(finished_at: nil).count
      completed = SolidQueue::Job.where.not(finished_at: nil).count
      failed = SolidQueue::FailedExecution.count
      scheduled = SolidQueue::ScheduledExecution.count
      ready = SolidQueue::ReadyExecution.count
      claimed = SolidQueue::ClaimedExecution.count

      puts "Solid Queue Status"
      puts "-" * 30
      puts "  Ready:     #{ready}"
      puts "  Claimed:   #{claimed}"
      puts "  Scheduled: #{scheduled}"
      puts "  Pending:   #{pending}"
      puts "  Completed: #{completed}"
      puts "  Failed:    #{failed}"
      puts ""
      puts "Web UI: http://localhost:3000/jobs"
    end

    desc "Clear all pending jobs (keeps completed and failed)"
    task clear: :environment do
      ready = SolidQueue::ReadyExecution.count
      claimed = SolidQueue::ClaimedExecution.count
      scheduled = SolidQueue::ScheduledExecution.count

      # Get job IDs that have failed executions so we can exclude them
      failed_job_ids = SolidQueue::FailedExecution.pluck(:job_id)

      SolidQueue::ReadyExecution.destroy_all
      SolidQueue::ClaimedExecution.destroy_all
      SolidQueue::ScheduledExecution.destroy_all
      SolidQueue::Job.where(finished_at: nil).where.not(id: failed_job_ids).destroy_all

      puts "Cleared pending jobs (kept #{failed_job_ids.size} failed):"
      puts "  Ready: #{ready}"
      puts "  Claimed: #{claimed}"
      puts "  Scheduled: #{scheduled}"
    end

    desc "Clear all jobs (including completed)"
    task clear_all: :environment do
      count = SolidQueue::Job.count

      SolidQueue::Job.destroy_all
      SolidQueue::FailedExecution.destroy_all

      puts "Cleared all #{count} jobs"
    end

    desc "Clear failed jobs"
    task clear_failed: :environment do
      count = SolidQueue::FailedExecution.count
      SolidQueue::FailedExecution.destroy_all
      puts "Cleared #{count} failed jobs"
    end

    desc "Retry all failed jobs"
    task retry_failed: :environment do
      count = 0
      SolidQueue::FailedExecution.find_each do |failed|
        failed.retry
        count += 1
      end
      puts "Retried #{count} failed jobs"
    end
  end


  desc "Process a video file through the full pipeline: import, transcribe, embed"
  task :process, [:source_path, :project_name] => :environment do |_t, args|
    source_path = args[:source_path]
    project_name = args[:project_name] || "Default Project"

    abort "Usage: rake cm:process[/path/to/video.mp4]" if source_path.blank?
    abort "File not found: #{source_path}" unless File.exist?(source_path)

    puts "=" * 60
    puts "Cuttymark Video Processing Pipeline"
    puts "=" * 60
    puts ""

    check_dependencies!

    project = Project.find_or_create_by!(name: project_name) do |p|
      p.description = "Created by cm:process task"
    end

    puts "Source: #{source_path}"
    puts "Project: #{project.name}"
    puts ""

    start_time = Time.current
    transcript = Video.import_and_process!(source_path, project: project)
    elapsed = Time.current - start_time

    video = transcript.video
    puts "=" * 60
    puts "Processing Complete"
    puts "=" * 60
    puts "  Video ID: #{video.id}"
    puts "  Duration: #{format_duration(video.duration_seconds)}"
    puts "  Words: #{transcript.word_segments.count}"
    puts "  Sentences: #{transcript.sentence_segments.count}"
    puts "  Elapsed: #{format_duration(elapsed)}"
    puts "  Web UI: http://localhost:3000/videos/#{video.id}"
    puts ""
  end

  desc "Process all unprocessed video files in storage/sources (includes retrying failed)"
  task :process_all, [:project_name] => :environment do |_t, args|
    project_name = args[:project_name] || "Default Project"
    sources_dir = Rails.root.join("storage", "sources")

    puts "=" * 60
    puts "Cuttymark Batch Processing"
    puts "=" * 60
    puts ""

    project = Project.find_or_create_by!(name: project_name) do |p|
      p.description = "Created by cm:process_all task"
    end
    puts "Project: #{project.name} (ID: #{project.id})"
    puts ""

    unless Dir.exist?(sources_dir)
      abort "Sources directory not found: #{sources_dir}"
    end

    # Find all videos needing processing (for reporting)
    work = Video.needing_processing(sources_dir: sources_dir)
    new_files = work[:new_files]
    pending_videos = work[:pending]
    failed_videos = work[:failed]

    # Report what we found
    puts "Status:"
    puts "  New files to import: #{new_files.size}"
    puts "  Pending transcription: #{pending_videos.size}"
    puts "  Failed videos to retry: #{failed_videos.size}"
    puts ""

    if new_files.empty? && pending_videos.empty? && failed_videos.empty?
      puts "Nothing to process!"
      puts "  Already processed: #{Video.count} videos"
      exit 0
    end

    # Show preview of work
    if new_files.any?
      puts "New file(s) to import:"
      new_files.first(5).each_with_index do |path, i|
        relative = Pathname.new(path).relative_path_from(sources_dir)
        size = number_to_human_size(File.size(path))
        puts "  #{i + 1}. #{relative} (#{size})"
      end
      puts "  ... and #{new_files.size - 5} more" if new_files.size > 5
      puts ""
    end

    if pending_videos.any?
      puts "Pending video(s) to transcribe:"
      pending_videos.first(5).each_with_index do |video, i|
        puts "  #{i + 1}. #{video.filename} (ID: #{video.id})"
      end
      puts "  ... and #{pending_videos.size - 5} more" if pending_videos.size > 5
      puts ""
    end

    if failed_videos.any?
      puts "Failed video(s) to retry:"
      failed_videos.first(5).each_with_index do |video, i|
        error_msg = video.transcript&.error_message || "Unknown error"
        puts "  #{i + 1}. #{video.filename} (ID: #{video.id})"
        puts "     Error: #{error_msg.truncate(60)}"
      end
      puts "  ... and #{failed_videos.size - 5} more" if failed_videos.size > 5
      puts ""
    end

    # Queue all jobs
    puts "-" * 60
    puts "Queueing jobs..."
    puts "-" * 60
    puts ""

    counts = Video.queue_all_needing_processing!(project: project, sources_dir: sources_dir) do |type, item|
      case type
      when :new
        relative = Pathname.new(item).relative_path_from(sources_dir)
        puts "  Queued NEW: #{relative}"
      when :pending
        puts "  Queued PENDING: #{item.filename} (ID: #{item.id})"
      when :failed
        puts "  Queued RETRY: #{item.filename} (ID: #{item.id})"
      end
    end

    total = counts[:new_files] + counts[:pending] + counts[:failed]

    puts ""
    puts "=" * 60
    puts "#{total} Jobs Queued"
    puts "=" * 60
    puts "  New imports: #{counts[:new_files]}"
    puts "  Pending: #{counts[:pending]}"
    puts "  Retries: #{counts[:failed]}"
    puts ""
    puts "Monitor progress: http://localhost:3000/jobs"
    puts "Wait for completion: rails cm:wait_for_jobs"
    puts ""
  end

  desc "Retry a specific failed video"
  task :retry, [:video_id] => :environment do |_t, args|
    video_id = args[:video_id]
    abort "Usage: rake cm:retry[VIDEO_ID]" if video_id.blank?

    check_dependencies!

    video = Video.find(video_id)
    puts "Retrying: #{video.filename} (ID: #{video.id})"

    start_time = Time.current
    transcript = video.retry!
    elapsed = Time.current - start_time

    puts ""
    puts "Retry Complete"
    puts "  Words: #{transcript.word_segments.count}"
    puts "  Sentences: #{transcript.sentence_segments.count}"
    puts "  Elapsed: #{format_duration(elapsed)}"
    puts "  Web UI: http://localhost:3000/videos/#{video.id}"
    puts ""
  end

  desc "Clean hallucinations from a video transcript"
  task :clean_hallucinations, [:video_id] => :environment do |_t, args|
    video_id = args[:video_id]
    abort "Usage: rake cm:clean_hallucinations[VIDEO_ID]" if video_id.blank?

    video = Video.find(video_id)
    transcript = video.transcript
    abort "Video has no transcript" unless transcript

    puts "=" * 60
    puts "Cleaning hallucinations from: #{video.filename}"
    puts "=" * 60
    puts ""

    puts "Before:"
    puts "  Total segments: #{transcript.segments.count}"
    puts "  Words: #{transcript.word_segments.count}"
    puts "  Sentences: #{transcript.sentence_segments.count}"
    puts ""

    stats = transcript.clean_hallucinations!

    puts "Cleanup stats:"
    stats.each { |k, v| puts "  #{k}: #{v}" }
    puts ""

    puts "After:"
    puts "  Total segments: #{transcript.segments.count}"
    puts "  Words: #{transcript.word_segments.count}"
    puts "  Sentences: #{transcript.sentence_segments.count}"
    puts ""
  end

  desc "Reprocess a single video from scratch (re-transcribe and re-embed)"
  task :reprocess, [:video_id, :engine] => :environment do |_t, args|
    video_id = args[:video_id]
    engine = args[:engine]&.to_sym
    abort "Usage: rake cm:reprocess[VIDEO_ID] or rake cm:reprocess[VIDEO_ID,gemini]" if video_id.blank?

    # Validate engine if provided
    if engine && !Transcription::ClientFactory::ENGINES.key?(engine)
      abort "Invalid engine: #{engine}. Available: #{Transcription::ClientFactory::ENGINES.keys.join(', ')}"
    end

    check_dependencies!(engine: engine)

    video = Video.find(video_id)
    engine_sym = engine || Transcription::ClientFactory.default_engine
    client = Transcription::ClientFactory.create(engine_sym)
    engine_display = client.respond_to?(:model_name) ? "#{engine_sym} (#{client.model_name})" : engine_sym.to_s

    puts "Reprocessing: #{video.filename} (ID: #{video.id})"
    puts "Engine: #{engine_display}"
    puts ""

    start_time = Time.current
    transcript = video.retry!(engine: engine)
    elapsed = Time.current - start_time

    puts ""
    puts "Reprocessing Complete"
    puts "  Engine: #{transcript.engine}"
    puts "  Words: #{transcript.word_segments.count}"
    puts "  Sentences: #{transcript.sentence_segments.count}"
    puts "  Elapsed: #{format_duration(elapsed)}"
    puts "  Web UI: http://localhost:3000/videos/#{video.id}"
    puts ""
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

  def check_dependencies!(engine: nil)
    engine ||= Transcription::ClientFactory.default_engine

    case engine.to_sym
    when :whisper
      print "Checking Whisper server... "
      whisper = Transcription::WhisperClient.new
      unless whisper.health_check
        abort "FAILED\n\nWhisper server is not available at #{whisper.instance_variable_get(:@host)}:#{whisper.instance_variable_get(:@port)}"
      end
      puts "OK"
    when :gemini
      print "Checking Gemini API... "
      begin
        gemini = Transcription::GeminiClient.new
        unless gemini.health_check
          abort "FAILED\n\nGemini API is not available. Check GEMINI_API_KEY."
        end
        puts "OK"
      rescue ArgumentError => e
        abort "FAILED\n\n#{e.message}"
      end
    end

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

  desc "Search a video transcript for a phrase"
  task :search, [:video_id, :query] => :environment do |_t, args|
    video_id = args[:video_id]
    query = args[:query]

    abort "Usage: rake cm:search[VIDEO_ID,'search query']" if video_id.blank? || query.blank?

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
