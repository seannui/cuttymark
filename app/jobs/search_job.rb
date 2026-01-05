class SearchJob < ApplicationJob
  queue_as :default

  def perform(search_query_id)
    search_query = SearchQuery.find(search_query_id)

    Rails.logger.info("[SearchJob] Executing search: '#{search_query.query_text}' (#{search_query.match_type})")

    service = Search::SearchService.new
    matches = service.execute(search_query)

    Rails.logger.info("[SearchJob] Found #{matches.size} matches for search query: #{search_query.id}")
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("[SearchJob] SearchQuery not found: #{search_query_id}")
    raise e
  end
end
