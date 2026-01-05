class SearchQueriesController < ApplicationController
  before_action :set_search_query, only: %i[show destroy]

  def index
    @search_queries = SearchQuery.includes(:project, :matches).order(created_at: :desc)
  end

  def show
    @matches = @search_query.matches
                            .includes(segment: { transcript: :video })
                            .ordered_by_relevance
  end

  def new
    @search_query = SearchQuery.new
    @search_query.project_id = params[:project_id] if params[:project_id]
    @projects = Project.order(:name)
  end

  def create
    @search_query = SearchQuery.new(search_query_params)

    if @search_query.save
      # Check for semantic search requirements
      if @search_query.semantic?
        ollama = Embeddings::OllamaClient.new
        unless ollama.health_check
          @search_query.destroy
          flash[:alert] = "Ollama is not available. Please start it with: ollama serve"
          @projects = Project.order(:name)
          render :new, status: :unprocessable_entity
          return
        end
      end

      # Execute search in background job
      SearchJob.perform_later(@search_query.id)
      redirect_to @search_query, notice: "Search started. Results will appear shortly."
    else
      @projects = Project.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    project = @search_query.project
    @search_query.destroy
    redirect_to project_path(project), notice: "Search query was deleted."
  end

  private

  def set_search_query
    @search_query = SearchQuery.find(params[:id])
  end

  def search_query_params
    params.require(:search_query).permit(:project_id, :query_text, :match_type)
  end
end
