class ClipsController < ApplicationController
  before_action :set_clip, only: %i[show edit update destroy render_clip stream thumbnail]

  def index
    @clips = Clip.includes(:video, :match).order(created_at: :desc)
  end

  def show
  end

  def new
    @clip = Clip.new
    @clip.video_id = params[:video_id] if params[:video_id]
    @clip.match_id = params[:match_id] if params[:match_id]

    if @clip.match_id && (match = Match.find_by(id: @clip.match_id))
      @clip.start_time = match.segment.start_time
      @clip.end_time = match.segment.end_time
    end

    @videos = Video.includes(:project).order(:filename)
  end

  def create
    @clip = Clip.new(clip_params)

    if @clip.save
      # Auto-render the clip if source file exists
      if File.exist?(@clip.source_path)
        ClipRenderJob.perform_later(@clip.id)
        redirect_to @clip, notice: "Clip created and rendering started."
      else
        redirect_to @clip, notice: "Clip was successfully created."
      end
    else
      @videos = Video.includes(:project).order(:filename)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @videos = Video.includes(:project).order(:filename)
  end

  def update
    if @clip.update(clip_params)
      redirect_to @clip, notice: "Clip was successfully updated."
    else
      @videos = Video.includes(:project).order(:filename)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @clip.destroy
    redirect_back fallback_location: clips_path, notice: "Clip was successfully deleted."
  end

  def render_clip
    unless File.exist?(@clip.source_path)
      redirect_to @clip, alert: "Source video file not found: #{@clip.source_path}"
      return
    end

    # Allow re-rendering by resetting the clip state
    if @clip.rendered? || @clip.failed?
      @clip.reset_for_rerender!
    end

    ClipRenderJob.perform_later(@clip.id)
    redirect_to @clip, notice: "Clip rendering started."
  end

  def stream
    unless @clip.rendered? && @clip.export_path.present? && File.exist?(@clip.export_path)
      head :not_found
      return
    end

    send_file @clip.export_path,
              type: "video/mp4",
              disposition: "inline",
              stream: true,
              buffer_size: 16.kilobytes
  end

  def thumbnail
    unless @clip.thumbnail_path.present? && File.exist?(@clip.thumbnail_path)
      head :not_found
      return
    end

    send_file @clip.thumbnail_path,
              type: "image/png",
              disposition: "inline"
  end

  private

  def set_clip
    @clip = Clip.find(params[:id])
  end

  def clip_params
    params.require(:clip).permit(:video_id, :match_id, :title, :start_time, :end_time, :notes)
  end
end
