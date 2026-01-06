module ApplicationHelper
  def sortable_header(column, title, current_sort, current_direction, options = {})
    is_current = current_sort == column
    next_direction = is_current && current_direction == "asc" ? "desc" : "asc"

    # Preserve existing params (filters, search, etc.) while updating sort
    sort_params = request.query_parameters.merge(sort: column, direction: next_direction, page: nil)

    link_to videos_path(sort_params), class: "group inline-flex items-center gap-1", data: { turbo_frame: "videos_table", turbo_action: "advance" } do
      concat content_tag(:span, title)
      concat sort_indicator(column, current_sort, current_direction)
    end
  end

  private

  def sort_indicator(column, current_sort, current_direction)
    if current_sort == column
      if current_direction == "asc"
        # Up arrow (ascending)
        content_tag(:svg, class: "h-4 w-4 text-indigo-600", fill: "none", stroke: "currentColor", viewBox: "0 0 24 24") do
          content_tag(:path, nil, "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-width": "2", d: "M5 15l7-7 7 7")
        end
      else
        # Down arrow (descending)
        content_tag(:svg, class: "h-4 w-4 text-indigo-600", fill: "none", stroke: "currentColor", viewBox: "0 0 24 24") do
          content_tag(:path, nil, "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-width": "2", d: "M19 9l-7 7-7-7")
        end
      end
    else
      # Neutral indicator (shows on hover)
      content_tag(:svg, class: "h-4 w-4 text-gray-400 opacity-0 group-hover:opacity-100 transition-opacity", fill: "none", stroke: "currentColor", viewBox: "0 0 24 24") do
        content_tag(:path, nil, "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-width": "2", d: "M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4")
      end
    end
  end
end
