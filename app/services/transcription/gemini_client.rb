require "net/http"
require "uri"
require "json"
require "base64"

module Transcription
  class GeminiClient < BaseClient
    API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
    DEFAULT_MODEL = "gemini-2.0-flash"
    FILE_SIZE_THRESHOLD = 20 * 1024 * 1024  # 20MB - use File API above this

    TRANSCRIPTION_PROMPT = <<~PROMPT.freeze
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

    def initialize(api_key: nil, model: nil)
      @api_key = api_key || ENV.fetch("GEMINI_API_KEY", nil)
      @model = model || ENV.fetch("GEMINI_MODEL", DEFAULT_MODEL)

      raise ArgumentError, "GEMINI_API_KEY is required" if @api_key.nil? || @api_key.empty?
    end

    def engine_name
      "gemini"
    end

    def transcribe(audio_path, **_options)
      raise ArgumentError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      Rails.logger.info("Gemini transcription starting for: #{audio_path}")

      file_size = File.size(audio_path)
      Rails.logger.info("Audio file size: #{(file_size / 1024.0 / 1024.0).round(2)} MB")

      response = if file_size > FILE_SIZE_THRESHOLD
                   transcribe_with_file_api(audio_path)
                 else
                   transcribe_inline(audio_path)
                 end

      parse_response(response)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise ConnectionError, "Cannot connect to Gemini API: #{e.message}"
    rescue Net::ReadTimeout => e
      raise TranscriptionError, "Gemini transcription timed out: #{e.message}"
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

    def transcribe_inline(audio_path)
      Rails.logger.info("Using inline transcription (file under 20MB)")

      audio_data = Base64.strict_encode64(File.binread(audio_path))
      mime_type = detect_mime_type(audio_path)

      payload = {
        contents: [{
          parts: [
            { text: TRANSCRIPTION_PROMPT },
            { inline_data: { mime_type: mime_type, data: audio_data } }
          ]
        }],
        generationConfig: {
          responseMimeType: "application/json"
        }
      }

      make_generate_request(payload)
    end

    def transcribe_with_file_api(audio_path)
      Rails.logger.info("Using File API for large file upload")

      # Step 1: Upload file
      file_uri = upload_file(audio_path)
      Rails.logger.info("File uploaded: #{file_uri}")

      # Step 2: Generate transcription using uploaded file
      payload = {
        contents: [{
          parts: [
            { text: TRANSCRIPTION_PROMPT },
            { file_data: { mime_type: detect_mime_type(audio_path), file_uri: file_uri } }
          ]
        }],
        generationConfig: {
          responseMimeType: "application/json"
        }
      }

      result = make_generate_request(payload)

      # Step 3: Delete uploaded file (cleanup)
      delete_file(file_uri)

      result
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

    def parse_response(response)
      # Extract text content from Gemini response
      text_content = response.dig("candidates", 0, "content", "parts", 0, "text")

      raise TranscriptionError, "Empty response from Gemini" if text_content.nil? || text_content.empty?

      # Parse JSON response
      data = begin
        JSON.parse(text_content)
      rescue JSON::ParserError => e
        Rails.logger.error("Failed to parse Gemini response as JSON: #{text_content[0..500]}")
        raise TranscriptionError, "Invalid JSON response from Gemini: #{e.message}"
      end

      Result.new(
        text: data["text"]&.strip,
        language: data["language"] || "en",
        duration: calculate_duration(data),
        segments: parse_segments(data["segments"] || []),
        words: parse_words(data["words"] || [])
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

    def calculate_duration(data)
      # Calculate duration from the last segment or word
      last_segment = data["segments"]&.last
      last_word = data["words"]&.last

      [
        last_segment&.dig("end").to_f,
        last_word&.dig("end").to_f
      ].max
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
