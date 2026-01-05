class VideosController < ApplicationController
  before_action :set_video, only: %i[show edit update destroy transcribe]

  def index
    @videos = Video.includes(:project, :transcript).order(created_at: :desc)
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
    sources_dir = Rails.root.join("storage", "sources")
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
      redirect_to @video, alert: ".braw files require a proxy. Please convert to MP4 first."
      return
    end

    unless File.exist?(@video.playable_path)
      redirect_to @video, alert: "Video file not found at: #{@video.playable_path}"
      return
    end

    # Check if Whisper server is available
    whisper = Transcription::WhisperClient.new
    unless whisper.health_check
      redirect_to @video, alert: "Whisper server is not available. Please start it first."
      return
    end

    @video.update!(status: :transcribing)
    TranscriptionJob.perform_later(@video.id)

    redirect_to @video, notice: "Transcription started. This may take a while for long videos."
  end

  private

  def set_video
    @video = Video.find(params[:id])
  end

  def video_params
    params.require(:video).permit(:project_id, :source_path, :filename, :proxy_path)
  end
end
