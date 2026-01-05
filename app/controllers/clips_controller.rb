class ClipsController < ApplicationController
  before_action :set_clip, only: %i[show edit update destroy render_clip]

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
      redirect_to @clip, notice: "Clip was successfully created."
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
    video = @clip.video
    @clip.destroy
    redirect_to video_path(video), notice: "Clip was successfully deleted."
  end

  def render_clip
    unless File.exist?(@clip.source_path)
      redirect_to @clip, alert: "Source video file not found: #{@clip.source_path}"
      return
    end

    if @clip.rendered?
      redirect_to @clip, alert: "Clip has already been rendered."
      return
    end

    ClipRenderJob.perform_later(@clip.id)
    redirect_to @clip, notice: "Clip rendering started."
  end

  private

  def set_clip
    @clip = Clip.find(params[:id])
  end

  def clip_params
    params.require(:clip).permit(:video_id, :match_id, :title, :start_time, :end_time, :notes)
  end
end
