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

  # Make spaceless transcript text readable by inserting spaces at word boundaries.
  def humanize_transcript(text)
    text.gsub(/([a-z])([A-Z])/, '\1 \2')
        .gsub(/([.!?,;:])([A-Za-z])/, '\1 \2')
        .gsub(/([a-z])(-)([A-Z])/, '\1 \2 \3')
  end

  # Build an HTML excerpt from transcript text with the query phrase highlighted.
  # Returns an html_safe string with <mark> around the matched phrase and surrounding context.
  def transcript_excerpt(text, query_text, context_chars: 100)
    readable = humanize_transcript(text)

    # Strategy 1: Direct case-insensitive match (works for properly spaced text like raw_text)
    direct_pos = readable.downcase.index(query_text.downcase)
    if direct_pos
      match_end = direct_pos + query_text.length
      return build_highlighted_excerpt(readable, direct_pos, match_end, context_chars)
    end

    # Strategy 2: Space-stripped matching (works for spaceless segment text)
    query_normalized = query_text.gsub(/\s+/, "").downcase
    readable_no_spaces = readable.downcase.gsub(/\s+/, "")
    match_pos = readable_no_spaces.index(query_normalized)

    if match_pos
      # Map position back to the readable (spaced) string
      char_count = 0
      real_start = nil
      real_end = nil
      readable.each_char.with_index do |c, i|
        if c =~ /\S/
          real_start = i if char_count == match_pos
          if char_count == match_pos + query_normalized.length - 1
            real_end = i + 1
            break
          end
          char_count += 1
        end
      end

      if real_start && real_end
        return build_highlighted_excerpt(readable, real_start, real_end, context_chars)
      end
    end

    # No direct match found — show readable text truncated
    h(readable.truncate(250))
  end

  def build_highlighted_excerpt(readable, match_start, match_end, context_chars)
    ctx_start = [match_start - context_chars, 0].max
    ctx_start = readable.rindex(/[.!?]\s/, ctx_start)&.+(2) || ctx_start
    ctx_end = [match_end + context_chars, readable.length].min
    ctx_end = readable.index(/[.!?]/, ctx_end - 1)&.+(1) || ctx_end

    before = (ctx_start > 0 ? "..." : "") + readable[ctx_start...match_start].to_s
    matched = readable[match_start...match_end].to_s
    after = readable[match_end...ctx_end].to_s + (ctx_end < readable.length ? "..." : "")

    safe_join([
      h(before),
      content_tag(:mark, h(matched), class: "bg-yellow-200 rounded px-0.5"),
      h(after)
    ])
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
