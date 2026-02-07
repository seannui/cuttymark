class VideosController < ApplicationController
  before_action :set_video, only: %i[show edit update destroy transcribe reprocess]

  # Allowed sort columns and their SQL expressions
  SORT_COLUMNS = {
    "filename" => "videos.filename",
    "project" => "projects.name",
    "duration" => "videos.duration_seconds",
    "state" => "videos.state",
    "transcript" => "transcripts.state",
    "created_at" => "videos.created_at"
  }.freeze

  def index
    base_scope = Video.includes(:project, :transcript)

    # Filter by project
    if params[:project_id].present?
      base_scope = base_scope.where(project_id: params[:project_id])
      @filter_project = Project.find_by(id: params[:project_id])
    end

    # Filter by video state
    if params[:state].present? && Video.aasm.states.map(&:name).map(&:to_s).include?(params[:state])
      base_scope = base_scope.where(state: params[:state])
      @filter_state = params[:state]
    end

    # Filter by transcript status
    if params[:transcript].present?
      case params[:transcript]
      when "none"
        base_scope = base_scope.where.missing(:transcript)
      when "completed"
        base_scope = base_scope.joins(:transcript).where(transcripts: { state: "completed" })
      when "failed"
        base_scope = base_scope.joins(:transcript).where(transcripts: { state: "failed" })
      when "processing"
        base_scope = base_scope.joins(:transcript).where.not(transcripts: { state: %w[completed failed] })
      end
      @filter_transcript = params[:transcript]
    end

    if params[:q].present?
      @filter_query = params[:q]

      # Filename matches
      @videos = base_scope.where("filename ILIKE ?", "%#{params[:q]}%")

      # Full-text transcript search
      @transcript_matches = perform_transcript_search(base_scope) if params[:q].length >= 3

      # Semantic transcript search (supplements full-text results)
      if params[:q].length >= 3
        semantic_matches = perform_semantic_search(base_scope)
        if semantic_matches.present?
          @transcript_matches = merge_transcript_matches(@transcript_matches, semantic_matches)
        end
      end
    else
      @videos = base_scope
    end

    # Sorting
    @sort_column = SORT_COLUMNS.key?(params[:sort]) ? params[:sort] : "created_at"
    @sort_direction = %w[asc desc].include?(params[:direction]) ? params[:direction] : "desc"

    @videos = apply_sorting(@videos, @sort_column, @sort_direction)

    # Counts for filter badges (before pagination)
    @total_count = Video.count
    @state_counts = Video.group(:state).count
    @projects = Project.order(:name)

    # Paginate
    @videos = @videos.page(params[:page]).per(25)
  end

  def show
    @transcript = @video.transcript
    @clips = @video.clips.ordered
  end

  def new
    @video = Video.new
    @video.project_id = params[:project_id] if params[:project_id]
    @projects = Project.order(:name)
    @available_files = scan_source_files
  end

  private

  def scan_source_files
    sources_dir = Video.sources_dir
    return [] unless Dir.exist?(sources_dir)

    # Get already imported source paths
    imported_paths = Video.pluck(:source_path).compact.to_set

    # Supported video extensions
    extensions = Video::SUPPORTED_FORMATS + [Video::BRAW_FORMAT]
    pattern = File.join(sources_dir, "**", "*.{#{extensions.join(',')}}")

    Dir.glob(pattern, File::FNM_CASEFOLD).filter_map do |path|
      next if imported_paths.include?(path)

      # Get relative path from sources directory for display
      relative_path = Pathname.new(path).relative_path_from(sources_dir).to_s

      {
        path: path,
        display_name: relative_path,
        filename: File.basename(path),
        size: File.size(path),
        size_human: number_to_human_size(File.size(path)),
        extension: File.extname(path).delete(".").downcase
      }
    end.sort_by { |f| f[:display_name].downcase }
  end

  def number_to_human_size(bytes)
    return "0 B" unless bytes&.positive?

    units = %w[B KB MB GB TB]
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = units.size - 1 if exp > units.size - 1

    "%.1f %s" % [bytes.to_f / 1024**exp, units[exp]]
  end

  public

  def create
    source_path = video_params[:source_path]

    # Use import service if source path exists on disk
    if source_path.present? && File.exist?(source_path)
      project = Project.find(video_params[:project_id])
      import_service = VideoProcessing::ImportService.new
      @video = import_service.import(source_path, project: project, filename: video_params[:filename])
      redirect_to @video, notice: "Video was successfully imported."
    else
      @video = Video.new(video_params)
      if @video.save
        redirect_to @video, notice: "Video was successfully added."
      else
        @projects = Project.order(:name)
        render :new, status: :unprocessable_entity
      end
    end
  rescue VideoProcessing::ImportService::Error => e
    @video = Video.new(video_params)
    @video.errors.add(:source_path, e.message)
    @projects = Project.order(:name)
    render :new, status: :unprocessable_entity
  end

  def edit
    @projects = Project.order(:name)
  end

  def update
    if @video.update(video_params)
      redirect_to @video, notice: "Video was successfully updated."
    else
      @projects = Project.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    project = @video.project
    @video.destroy
    redirect_to project_path(project), notice: "Video was successfully deleted."
  end

  def transcribe
    if @video.braw? && @video.proxy_path.blank?
      redirect_back fallback_location: @video, alert: ".braw files require a proxy. Please convert to MP4 first."
      return
    end

    unless File.exist?(@video.playable_path)
      redirect_back fallback_location: @video, alert: "Video file not found at: #{@video.playable_path}"
      return
    end

    # Check if transcription engine is available
    unless transcription_engine_available?
      redirect_back fallback_location: @video, alert: transcription_engine_error_message
      return
    end

    @video.start_transcription!
    TranscriptionJob.perform_later(@video.id)

    redirect_back fallback_location: @video, notice: "Transcription started for #{@video.filename}."
  end

  def reprocess
    if @video.braw? && @video.proxy_path.blank?
      redirect_back fallback_location: @video, alert: ".braw files require a proxy. Please convert to MP4 first."
      return
    end

    unless File.exist?(@video.playable_path)
      redirect_back fallback_location: @video, alert: "Video file not found at: #{@video.playable_path}"
      return
    end

    # Check if transcription engine is available
    unless transcription_engine_available?
      redirect_back fallback_location: @video, alert: transcription_engine_error_message
      return
    end

    # Reset and queue for reprocessing
    @video.reset_for_reprocessing!
    @video.queue_for_reprocessing!

    redirect_back fallback_location: @video, notice: "Reprocessing started for #{@video.filename}."
  end

  private

  def set_video
    @video = Video.find(params[:id])
  end

  def video_params
    params.require(:video).permit(:project_id, :source_path, :filename, :proxy_path)
  end

  def apply_sorting(scope, column, direction)
    sql_column = SORT_COLUMNS[column]
    dir = direction == "asc" ? :asc : :desc

    case column
    when "project"
      scope.joins(:project).order(Arel.sql("#{sql_column} #{dir}"))
    when "transcript"
      scope.left_joins(:transcript).order(Arel.sql("#{sql_column} #{dir} NULLS LAST"))
    else
      scope.order(Arel.sql("#{sql_column} #{dir}"))
    end
  end

  def perform_transcript_search(base_scope)
    query_text = params[:q]

    # Build transcript scope with same filters
    transcripts = Transcript.joins(:video).where(state: "completed").where.not(search_vector: nil)
    transcripts = transcripts.where(videos: { project_id: params[:project_id] }) if params[:project_id].present?
    if params[:state].present? && Video.aasm.states.map(&:name).map(&:to_s).include?(params[:state])
      transcripts = transcripts.where(videos: { state: params[:state] })
    end

    # Full-text search using plainto_tsquery (AND-combined terms)
    sanitized_query = Transcript.sanitize_sql_array(["plainto_tsquery('english', ?)", query_text])
    matched = transcripts
      .where("search_vector @@ #{sanitized_query}")
      .select("transcripts.*, ts_rank(search_vector, #{sanitized_query}) AS rank")
      .order("rank DESC")
      .limit(20)
      .includes(:video)

    # Exclude videos already found in filename search
    filename_video_ids = base_scope.where("filename ILIKE ?", "%#{query_text}%").pluck(:id).to_set

    matches = matched.filter_map do |transcript|
      next if filename_video_ids.include?(transcript.video_id)

      {
        video: transcript.video,
        segment: nil,
        similarity: transcript.respond_to?(:rank) ? (0.5 + transcript.rank.to_f) : 0.8,
        text: transcript.raw_text.to_s,
        match_type: :fulltext
      }
    end

    matches.presence
  end

  def merge_transcript_matches(fulltext_matches, semantic_matches)
    fulltext_matches ||= []
    semantic_matches ||= []

    # Index existing video IDs from fulltext results
    existing_ids = fulltext_matches.map { |m| m[:video].id }.to_set

    # Append semantic matches that aren't already in fulltext results
    semantic_matches.each do |match|
      next if existing_ids.include?(match[:video].id)
      fulltext_matches << match
      existing_ids << match[:video].id
    end

    fulltext_matches.presence
  end

  def perform_semantic_search(base_scope)
    embedding = Embeddings::OllamaClient.new.embed(params[:q])
    return nil unless embedding

    # Build segment scope with same filters applied via video join
    segments = Segment.joins(transcript: :video)
      .where(segment_type: "sentence")
      .where.not(embedding: nil)

    # Apply project filter
    segments = segments.where(videos: { project_id: params[:project_id] }) if params[:project_id].present?

    # Apply video state filter
    if params[:state].present? && Video.aasm.states.map(&:name).map(&:to_s).include?(params[:state])
      segments = segments.where(videos: { state: params[:state] })
    end

    # Apply transcript filter
    if params[:transcript].present?
      case params[:transcript]
      when "none"
        return nil # No segments exist for videos without transcripts
      when "completed"
        segments = segments.where(transcripts: { state: "completed" })
      when "failed"
        segments = segments.where(transcripts: { state: "failed" })
      when "processing"
        segments = segments.where.not(transcripts: { state: %w[completed failed] })
      end
    end

    matched_segments = segments
      .nearest_neighbors(:embedding, embedding, distance: "cosine")
      .limit(100)

    # Get IDs of filename-matched videos to exclude from semantic results
    filename_video_ids = base_scope.where("filename ILIKE ?", "%#{params[:q]}%").pluck(:id).to_set

    # Group by video, keep best (lowest distance) segment per video
    grouped = {}
    matched_segments.each do |segment|
      similarity = 1.0 - segment.neighbor_distance
      break if similarity < 0.35

      video_id = segment.transcript.video_id
      next if filename_video_ids.include?(video_id)

      if !grouped[video_id] || similarity > grouped[video_id][:similarity]
        grouped[video_id] = {
          video: segment.transcript.video,
          segment: segment,
          similarity: similarity,
          text: segment.transcript.raw_text.presence || segment.text
        }
      end
    end

    matches = grouped.values.sort_by { |m| -m[:similarity] }.first(20)
    matches.presence
  rescue Embeddings::OllamaClient::ConnectionError, Embeddings::OllamaClient::Error => e
    Rails.logger.warn("Semantic search unavailable: #{e.message}")
    nil
  end

  def transcription_engine_available?
    engine = Transcription::ClientFactory.default_engine
    client = Transcription::ClientFactory.create(engine)
    client.health_check
  rescue StandardError
    false
  end

  def transcription_engine_error_message
    engine = Transcription::ClientFactory.default_engine
    case engine
    when :whisper
      "Whisper server is not available. Please start it first."
    when :gemini
      "Gemini API is not available. Check your GEMINI_API_KEY."
    else
      "Transcription engine (#{engine}) is not available."
    end
  end
end
