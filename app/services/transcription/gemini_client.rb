require "net/http"
require "uri"
require "json"
require "base64"

module Transcription
  class GeminiClient < BaseClient
    API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
    DEFAULT_MODEL = "gemini-2.5-flash"
    FILE_SIZE_THRESHOLD = 20 * 1024 * 1024  # 20MB - use File API above this

    # Compact prompt for long files - segments only, no word-level timestamps
    TRANSCRIPTION_PROMPT_COMPACT = <<~PROMPT.freeze
      Transcribe this audio file COMPLETELY from start to end with speaker labels and accurate timestamps.

      Return the transcription in this exact JSON format:
      {
        "text": "complete transcript without timestamps",
        "language": "detected language code (e.g., en)",
        "audio_duration": 120.5,
        "segments": [
          {
            "start": 0.0,
            "end": 5.2,
            "text": "segment text (one or more sentences)",
            "speaker": "Speaker 1"
          }
        ]
      }

      CRITICAL REQUIREMENTS:
      - Transcribe the ENTIRE audio from beginning to end - do not stop early
      - Timestamps must be accurate to the actual audio timing
      - The first segment should start near 0.0 seconds
      - The last segment should end near the total audio duration
      - Each segment should be 1-3 sentences (not individual words)
      - Include timestamps in seconds (floating point)
      - Include audio_duration field with total length in seconds
      - Label speakers consistently (Speaker 1, Speaker 2, etc.)
      - Return ONLY valid JSON, no markdown or explanation
    PROMPT

    # Full prompt with word-level timestamps for short files
    TRANSCRIPTION_PROMPT_FULL = <<~PROMPT.freeze
      Transcribe this audio verbatim with speaker labels and timestamps.

      Return the transcription in this exact JSON format:
      {
        "text": "complete transcript without timestamps",
        "language": "detected language code (e.g., en)",
        "segments": [
          {
            "start": 0.0,
            "end": 5.2,
            "text": "segment text",
            "speaker": "Speaker 1"
          }
        ],
        "words": [
          {
            "start": 0.0,
            "end": 0.5,
            "word": "Hello",
            "speaker": "Speaker 1"
          }
        ]
      }

      Important:
      - Include timestamps in seconds (floating point)
      - Label speakers consistently (Speaker 1, Speaker 2, etc.)
      - Include every word with accurate timestamps
      - Return ONLY valid JSON, no markdown or explanation
    PROMPT

    # Audio longer than this uses chunked transcription
    # gemini-2.0-flash has 8k output token limit (~32k chars)
    # A 2-minute video with full word timestamps can hit this limit
    LONG_AUDIO_THRESHOLD = 120  # 2 minutes

    def initialize(api_key: nil, model: nil)
      @api_key = api_key || ENV.fetch("GEMINI_API_KEY", nil)
      @model = model || ENV.fetch("GEMINI_MODEL", DEFAULT_MODEL)

      raise ArgumentError, "GEMINI_API_KEY is required" if @api_key.nil? || @api_key.empty?
    end

    def engine_name
      "gemini"
    end

    def model_name
      @model
    end

    def transcribe(audio_path, **_options)
      raise ArgumentError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      Rails.logger.info("Gemini transcription starting for: #{audio_path}")

      file_size = File.size(audio_path)
      Rails.logger.info("Audio file size: #{(file_size / 1024.0 / 1024.0).round(2)} MB")

      # Get audio duration to decide on chunking
      @ffmpeg ||= VideoProcessing::FfmpegClient.new
      audio_duration = @ffmpeg.get_audio_duration(audio_path)

      if audio_duration > LONG_AUDIO_THRESHOLD
        Rails.logger.info("Long audio (#{audio_duration.round(0)}s) - using chunked transcription")
        transcribe_chunked(audio_path, audio_duration)
      else
        Rails.logger.info("Short audio (#{audio_duration.round(0)}s) - single request")
        transcribe_single(audio_path)
      end
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise ConnectionError, "Cannot connect to Gemini API: #{e.message}"
    rescue Net::ReadTimeout => e
      raise TranscriptionError, "Gemini transcription timed out: #{e.message}"
    end

    def transcribe_single(audio_path)
      file_size = File.size(audio_path)

      # Always use compact mode to avoid MAX_TOKENS errors
      # Word timings are generated from segments afterward
      response = if file_size > FILE_SIZE_THRESHOLD
                   transcribe_with_file_api(audio_path, compact: true)
                 else
                   transcribe_inline(audio_path, compact: true)
                 end

      parse_response(response, compact: true)
    rescue TranscriptionError => e
      if e.message.include?("MAX_TOKENS")
        # Retry with chunked mode if single request exceeded token limit
        Rails.logger.warn("Single request hit MAX_TOKENS, falling back to chunked mode")
        audio_duration = @ffmpeg.get_audio_duration(audio_path)
        transcribe_chunked(audio_path, audio_duration)
      else
        raise
      end
    end

    def transcribe_chunked(audio_path, total_duration)
      chunk_duration = LONG_AUDIO_THRESHOLD  # 2 minutes per chunk
      overlap = 3  # 3 second overlap to avoid cutting words

      all_segments = []
      all_words = []
      full_text_parts = []
      language = "en"

      chunk_start = 0.0
      chunk_index = 0

      while chunk_start < total_duration
        chunk_end = [chunk_start + chunk_duration, total_duration].min
        actual_duration = chunk_end - chunk_start

        Rails.logger.info("Processing chunk #{chunk_index + 1}: #{format_time(chunk_start)} - #{format_time(chunk_end)}")

        # Extract chunk audio
        chunk_path = extract_audio_chunk(audio_path, chunk_start, actual_duration, chunk_index)

        unless File.exist?(chunk_path)
          Rails.logger.warn("Chunk #{chunk_index + 1} audio extraction failed, skipping")
          all_segments << SegmentData.new(
            start_time: chunk_start, end_time: chunk_end,
            text: "[Audio extraction failed]", confidence: 0.0, speaker: nil
          )
          full_text_parts << "[Audio extraction failed at #{format_time(chunk_start)} - #{format_time(chunk_end)}]"
          chunk_index += 1
          chunk_start = chunk_end - overlap
          chunk_start = chunk_end if chunk_start >= total_duration - overlap
          next
        end

        begin
          # Transcribe chunk
          response = transcribe_chunk_audio(chunk_path)
          result = parse_response(response, compact: true, expected_duration: actual_duration)

          # Scale timestamps if Gemini's coverage is significantly off
          scaled_segments = scale_timestamps_if_needed(result.segments, actual_duration)

          # Regenerate words from scaled segments (original words have wrong timing)
          scaled_words = generate_words_from_segments(scaled_segments)

          # Offset timestamps by chunk start time
          offset_segments = scaled_segments.map do |seg|
            SegmentData.new(
              start_time: seg.start_time + chunk_start,
              end_time: seg.end_time + chunk_start,
              text: seg.text,
              confidence: seg.confidence,
              speaker: seg.speaker
            )
          end

          offset_words = scaled_words.map do |word|
            WordData.new(
              start_time: word.start_time + chunk_start,
              end_time: word.end_time + chunk_start,
              text: word.text,
              confidence: word.confidence,
              speaker: word.speaker
            )
          end

          all_segments.concat(offset_segments)
          all_words.concat(offset_words)
          full_text_parts << result.text if result.text.present?
          language = result.language

          Rails.logger.info("Chunk #{chunk_index + 1}: #{offset_segments.size} segments, #{offset_words.size} words")
        rescue TranscriptionError => e
          if e.message.include?("PROHIBITED_CONTENT") || e.message.include?("blocked")
            Rails.logger.warn("Chunk #{chunk_index + 1} blocked by safety filter, skipping: #{e.message}")
            placeholder = "[Content blocked by safety filter]"
          elsif e.message.include?("Invalid JSON")
            Rails.logger.warn("Chunk #{chunk_index + 1} returned malformed JSON, skipping: #{e.message}")
            placeholder = "[Chunk transcription failed - malformed response]"
          elsif e.message.include?("MAX_TOKENS")
            Rails.logger.warn("Chunk #{chunk_index + 1} hit MAX_TOKENS, skipping: #{e.message}")
            placeholder = "[Chunk transcription truncated]"
          elsif e.message.include?("Empty response")
            Rails.logger.warn("Chunk #{chunk_index + 1} returned empty response, skipping")
            placeholder = nil
          else
            raise
          end

          if placeholder
            all_segments << SegmentData.new(
              start_time: chunk_start,
              end_time: chunk_end,
              text: placeholder,
              confidence: 0.0,
              speaker: nil
            )
            full_text_parts << "#{placeholder} at #{format_time(chunk_start)} - #{format_time(chunk_end)}"
          end
        ensure
          # Clean up chunk file
          File.delete(chunk_path) if File.exist?(chunk_path)
        end

        chunk_index += 1
        chunk_start = chunk_end - overlap  # Overlap to catch word boundaries
        chunk_start = chunk_end if chunk_start >= total_duration - overlap  # Avoid tiny final chunk
      end

      # Merge overlapping segments (remove duplicates from overlap regions)
      merged_segments = merge_overlapping_segments(all_segments, overlap)
      merged_words = merge_overlapping_words(all_words, overlap)

      Rails.logger.info("Chunked transcription complete: #{merged_segments.size} segments, #{merged_words.size} words")

      Result.new(
        text: full_text_parts.join(" "),
        language: language,
        duration: total_duration,
        segments: merged_segments,
        words: merged_words
      )
    end

    def health_check
      # Simple API connectivity check
      uri = URI.parse("#{API_BASE_URL}/models?key=#{@api_key}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5

      response = http.get(uri.request_uri)
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end

    private

    def extract_audio_chunk(audio_path, start_time, duration, chunk_index)
      chunk_dir = Rails.root.join("tmp", "gemini_chunks")
      FileUtils.mkdir_p(chunk_dir)
      chunk_path = chunk_dir.join("chunk_#{chunk_index}.wav").to_s

      @ffmpeg.extract_audio_segment(audio_path, chunk_path, start_time: start_time, duration: duration)
      chunk_path
    end

    def transcribe_chunk_audio(chunk_path)
      file_size = File.size(chunk_path)

      if file_size > FILE_SIZE_THRESHOLD
        transcribe_with_file_api(chunk_path, compact: true)
      else
        transcribe_inline(chunk_path, compact: true)
      end
    end

    def scale_timestamps_if_needed(segments, expected_duration)
      return segments if segments.empty?

      last_end = segments.map(&:end_time).max
      return segments if last_end.nil? || last_end <= 0

      # Allow 5% tolerance before scaling
      coverage_ratio = last_end / expected_duration
      if coverage_ratio < 0.95
        scale_factor = expected_duration / last_end
        Rails.logger.warn("Gemini timestamp coverage low (#{(coverage_ratio * 100).round(1)}%), scaling by #{scale_factor.round(3)}")

        return segments.map do |seg|
          SegmentData.new(
            start_time: seg.start_time * scale_factor,
            end_time: seg.end_time * scale_factor,
            text: seg.text,
            confidence: seg.confidence,
            speaker: seg.speaker
          )
        end
      end

      segments
    end

    def merge_overlapping_segments(segments, overlap)
      return segments if segments.empty?

      # Sort by start time and remove segments that fall entirely within overlap regions
      sorted = segments.sort_by(&:start_time)
      merged = [sorted.first]

      sorted[1..].each do |segment|
        last = merged.last
        # If this segment starts within overlap time of the last segment's end, skip it
        # (it's likely a duplicate from the overlap)
        if segment.start_time < last.end_time - 1  # 1 second tolerance
          # Keep the longer segment
          if segment.text.length > last.text.length
            merged[-1] = segment
          end
        else
          merged << segment
        end
      end

      merged
    end

    def merge_overlapping_words(words, overlap)
      return words if words.empty?

      sorted = words.sort_by(&:start_time)
      merged = [sorted.first]

      sorted[1..].each do |word|
        last = merged.last
        # Skip words that are too close to the previous word (duplicates from overlap)
        if word.start_time < last.end_time - 0.1  # 100ms tolerance
          next
        else
          merged << word
        end
      end

      merged
    end

    def format_time(seconds)
      mins = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      format("%d:%02d", mins, secs)
    end

    def transcribe_inline(audio_path, compact: false)
      Rails.logger.info("Using inline transcription (file under 20MB)")

      audio_data = Base64.strict_encode64(File.binread(audio_path))
      mime_type = detect_mime_type(audio_path)
      prompt = compact ? TRANSCRIPTION_PROMPT_COMPACT : TRANSCRIPTION_PROMPT_FULL

      payload = build_payload(
        { text: prompt },
        { inline_data: { mime_type: mime_type, data: audio_data } }
      )

      make_generate_request(payload)
    end

    def transcribe_with_file_api(audio_path, compact: false)
      Rails.logger.info("Using File API for large file upload")

      # Step 1: Upload file
      file_uri = upload_file(audio_path)
      Rails.logger.info("File uploaded: #{file_uri}")

      # Step 2: Generate transcription using uploaded file
      prompt = compact ? TRANSCRIPTION_PROMPT_COMPACT : TRANSCRIPTION_PROMPT_FULL
      payload = build_payload(
        { text: prompt },
        { file_data: { mime_type: detect_mime_type(audio_path), file_uri: file_uri } }
      )

      result = make_generate_request(payload)

      # Step 3: Delete uploaded file (cleanup)
      delete_file(file_uri)

      result
    end

    def build_payload(*parts)
      {
        contents: [{
          parts: parts
        }],
        generationConfig: {
          responseMimeType: "application/json",
          maxOutputTokens: 65536
        }
      }
    end

    def upload_file(audio_path)
      mime_type = detect_mime_type(audio_path)
      file_size = File.size(audio_path)
      display_name = File.basename(audio_path)

      # Start resumable upload
      start_uri = URI.parse("https://generativelanguage.googleapis.com/upload/v1beta/files?key=#{@api_key}")

      start_request = Net::HTTP::Post.new(start_uri.request_uri)
      start_request["X-Goog-Upload-Protocol"] = "resumable"
      start_request["X-Goog-Upload-Command"] = "start"
      start_request["X-Goog-Upload-Header-Content-Length"] = file_size.to_s
      start_request["X-Goog-Upload-Header-Content-Type"] = mime_type
      start_request["Content-Type"] = "application/json"
      start_request.body = { file: { display_name: display_name } }.to_json

      http = Net::HTTP.new(start_uri.host, start_uri.port)
      http.use_ssl = true
      http.read_timeout = 300

      start_response = http.request(start_request)

      unless start_response.is_a?(Net::HTTPSuccess)
        raise TranscriptionError, "Failed to start file upload: #{start_response.body}"
      end

      upload_url = start_response["X-Goog-Upload-URL"]

      # Upload file content
      upload_uri = URI.parse(upload_url)
      upload_request = Net::HTTP::Put.new(upload_uri.request_uri)
      upload_request["Content-Length"] = file_size.to_s
      upload_request["X-Goog-Upload-Offset"] = "0"
      upload_request["X-Goog-Upload-Command"] = "upload, finalize"
      upload_request.body = File.binread(audio_path)

      upload_http = Net::HTTP.new(upload_uri.host, upload_uri.port)
      upload_http.use_ssl = true
      upload_http.read_timeout = 600  # 10 minutes for large uploads

      upload_response = upload_http.request(upload_request)

      unless upload_response.is_a?(Net::HTTPSuccess)
        raise TranscriptionError, "Failed to upload file: #{upload_response.body}"
      end

      file_info = JSON.parse(upload_response.body)
      file_info.dig("file", "uri")
    end

    def delete_file(file_uri)
      # Extract file name from URI
      file_name = file_uri.split("/").last

      uri = URI.parse("#{API_BASE_URL}/files/#{file_name}?key=#{@api_key}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Delete.new(uri.request_uri)
      http.request(request)

      Rails.logger.info("Cleaned up uploaded file: #{file_name}")
    rescue StandardError => e
      Rails.logger.warn("Failed to delete uploaded file: #{e.message}")
    end

    def make_generate_request(payload)
      uri = URI.parse("#{API_BASE_URL}/models/#{@model}:generateContent?key=#{@api_key}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 3600  # 1 hour for long transcriptions

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = payload.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = begin
          JSON.parse(response.body)
        rescue StandardError
          response.body
        end
        raise TranscriptionError, "Gemini API error: #{response.code} - #{error_body}"
      end

      JSON.parse(response.body)
    end

    def parse_response(response, compact: false, expected_duration: nil)
      # Log token usage for debugging
      usage = response["usageMetadata"]
      if usage
        Rails.logger.info("Gemini token usage: prompt=#{usage['promptTokenCount']}, " \
                          "candidates=#{usage['candidatesTokenCount']}, " \
                          "thoughts=#{usage['thoughtsTokenCount'] || 0}, " \
                          "total=#{usage['totalTokenCount']}")
      end

      # Check for blocked content or safety issues
      if response["candidates"].nil? || response["candidates"].empty?
        block_reason = response.dig("promptFeedback", "blockReason")
        if block_reason
          raise TranscriptionError, "Gemini blocked request: #{block_reason}"
        end
        Rails.logger.error("Gemini response has no candidates: #{response.to_json[0..1000]}")
        raise TranscriptionError, "Empty response from Gemini (no candidates)"
      end

      candidate = response["candidates"].first
      finish_reason = candidate["finishReason"]

      # Check finish reason for issues
      if finish_reason && !%w[STOP END_TURN].include?(finish_reason)
        Rails.logger.warn("Gemini finish reason: #{finish_reason}")
        if finish_reason == "SAFETY"
          safety_ratings = candidate["safetyRatings"]
          raise TranscriptionError, "Gemini blocked for safety: #{safety_ratings}"
        elsif finish_reason == "MAX_TOKENS"
          tokens_used = usage&.dig("candidatesTokenCount") || "unknown"
          raise TranscriptionError, "Response truncated at #{tokens_used} tokens (MAX_TOKENS). Audio too long for single request."
        end
      end

      # Extract text content from Gemini response
      text_content = candidate.dig("content", "parts", 0, "text")

      if text_content.nil? || text_content.empty?
        Rails.logger.warn("Gemini returned no text content (audio may be silent or too short)")
        return Result.new(text: "", language: "en", duration: 0, segments: [], words: [])
      end

      # Sanitize JSON — Gemini sometimes returns timestamps in MM:SS.ms format
      # instead of numeric seconds (e.g., "1:07.41" instead of 67.41)
      sanitized_content = sanitize_timestamp_json(text_content)

      # Parse JSON response, attempting repair if initial parse fails
      data = begin
        JSON.parse(sanitized_content)
      rescue JSON::ParserError => e
        Rails.logger.warn("Initial JSON parse failed, attempting repair: #{e.message}")
        repaired = repair_json(sanitized_content)
        begin
          JSON.parse(repaired)
        rescue JSON::ParserError => e2
          Rails.logger.error("JSON repair failed (length=#{sanitized_content.length}): #{sanitized_content[0..500]}")
          raise TranscriptionError, "Invalid JSON response from Gemini: #{e2.message}"
        end
      end

      # Log if Gemini reports a different duration than expected
      if expected_duration && data["audio_duration"]
        reported = data["audio_duration"].to_f
        diff = (reported - expected_duration).abs
        if diff > 5
          Rails.logger.warn("Gemini reported duration #{reported.round(1)}s vs expected #{expected_duration.round(1)}s (diff: #{diff.round(1)}s)")
        end
      end

      segments = parse_segments(data["segments"] || [])

      # In compact mode, generate words from segment text
      words = if compact
                generate_words_from_segments(segments)
              else
                parse_words(data["words"] || [])
              end

      Result.new(
        text: data["text"]&.strip,
        language: data["language"] || "en",
        duration: calculate_duration(data),
        segments: segments,
        words: words
      )
    end

    def parse_segments(segments)
      segments.map do |seg|
        SegmentData.new(
          start_time: seg["start"].to_f,
          end_time: seg["end"].to_f,
          text: seg["text"]&.strip,
          confidence: 0.95,  # Gemini doesn't provide confidence scores
          speaker: seg["speaker"]
        )
      end
    end

    def parse_words(words)
      words.map do |word|
        WordData.new(
          start_time: word["start"].to_f,
          end_time: word["end"].to_f,
          text: word["word"]&.strip,
          confidence: 0.95,  # Gemini doesn't provide confidence scores
          speaker: word["speaker"]
        )
      end
    end

    # Generate word-level data from segments by splitting text and distributing time
    def generate_words_from_segments(segments)
      words = []

      segments.each do |segment|
        text = segment.text || ""
        segment_words = text.split(/\s+/).reject(&:empty?)
        next if segment_words.empty?

        duration = segment.end_time - segment.start_time
        word_duration = duration / segment_words.size

        segment_words.each_with_index do |word_text, i|
          word_start = segment.start_time + (i * word_duration)
          word_end = word_start + word_duration

          words << WordData.new(
            start_time: word_start,
            end_time: word_end,
            text: word_text,
            confidence: 0.90,  # Lower confidence for synthesized word timings
            speaker: segment.speaker
          )
        end
      end

      words
    end

    def calculate_duration(data)
      # Calculate duration from the last segment or word
      last_segment = data["segments"]&.last
      last_word = data["words"]&.last

      [
        last_segment&.dig("end").to_f,
        last_word&.dig("end").to_f
      ].max
    end

    # Convert MM:SS.ms or "MM:SS.ms" timestamp values to numeric seconds in JSON text
    # Also fix double-decimal malformations like 12.345.88 -> 12.35
    def sanitize_timestamp_json(json_text)
      # Match "start": "1:07.41" or "end": "1:07.41" (quoted MM:SS format)
      result = json_text.gsub(/("(?:start|end)":\s*)"(\d{1,3}):(\d{2}(?:\.\d+)?)"/) do
        prefix = $1
        minutes = $2.to_f
        seconds = $3.to_f
        "#{prefix}#{(minutes * 60 + seconds).round(2)}"
      end

      # Match "start": 1:07.41 or "end": 1:07.41 (unquoted — invalid JSON, causes parse error)
      result = result.gsub(/("(?:start|end)":\s*)(\d{1,3}):(\d{2}(?:\.\d+)?)/) do
        prefix = $1
        minutes = $2.to_f
        seconds = $3.to_f
        "#{prefix}#{(minutes * 60 + seconds).round(2)}"
      end

      # Fix double-decimal timestamps like 12.345.88 -> 12.35
      result.gsub(/("(?:start|end)":\s*)(\d+\.\d+)\.(\d+)/) do
        prefix = $1
        "#{prefix}#{$2.to_f.round(2)}"
      end
    end

    # Attempt to repair common Gemini JSON output issues:
    # - Unescaped quotes inside string values ("He said "Whoa!"" -> "He said \"Whoa!\"")
    # - Truncated JSON (add missing closing brackets)
    def repair_json(json_text)
      # Fix unescaped quotes inside string values
      # Strategy: walk through the JSON and escape internal quotes in string values
      repaired = json_text.gsub(/("(?:text|speaker)":\s*")(.*?)("(?:\s*[,\}]))/) do |_match|
        prefix = $1
        value = $2
        suffix = $3
        # Escape any unescaped quotes within the value
        escaped_value = value.gsub(/(?<!\\)"/, '\\"')
        "#{prefix}#{escaped_value}#{suffix}"
      end

      # Close any unclosed brackets/braces (truncated response)
      open_braces = repaired.count("{") - repaired.count("}")
      open_brackets = repaired.count("[") - repaired.count("]")
      repaired += "]" * open_brackets if open_brackets > 0
      repaired += "}" * open_braces if open_braces > 0

      repaired
    end

    def detect_mime_type(audio_path)
      extension = File.extname(audio_path).downcase.delete(".")

      case extension
      when "wav" then "audio/wav"
      when "mp3" then "audio/mp3"
      when "flac" then "audio/flac"
      when "m4a", "aac" then "audio/aac"
      when "ogg" then "audio/ogg"
      else "audio/wav"  # Default to WAV
      end
    end
  end
end
