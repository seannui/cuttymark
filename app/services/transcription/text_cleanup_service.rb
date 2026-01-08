require "net/http"
require "json"

module Transcription
  class TextCleanupService
    # Uses an LLM to fix broken words and spelling errors in transcribed text
    # while preserving the original structure

    CLEANUP_PROMPT = <<~PROMPT
      You are a text correction assistant. Fix any incorrectly split words in this transcription. For example:
      - "Re iner" should be "Reiner"
      - "camar ader ie" should be "camaraderie"
      - "que ued" should be "queued"
      - "tre st le" should be "trestle"

      Only output the corrected text, nothing else. Do not add explanations.

      Text:
    PROMPT

    def initialize(model: nil)
      @model = model || ENV.fetch("OLLAMA_CLEANUP_MODEL", "gpt-oss:20b")
      @host = ENV.fetch("OLLAMA_HOST", "http://localhost:11434")
    end

    def cleanup_segment(segment)
      return if segment.text.blank?

      cleaned_text = cleanup_text(segment.text)
      return if cleaned_text == segment.text

      segment.update!(text: cleaned_text)
      cleaned_text
    end

    def cleanup_transcript(transcript)
      count = 0
      transcript.segments.where(segment_type: "sentence").find_each do |segment|
        if cleanup_segment(segment)
          count += 1
        end
      end
      Rails.logger.info("TextCleanupService: cleaned #{count} segments for transcript #{transcript.id}")
      count
    end

    def cleanup_text(text)
      return text if text.blank?

      uri = URI("#{@host}/api/generate")
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request.body = {
        model: @model,
        prompt: "#{CLEANUP_PROMPT}#{text}",
        stream: false,
        options: {
          temperature: 0.1  # Low temperature for consistent corrections
        }
      }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 120, open_timeout: 10) do |http|
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        result = JSON.parse(response.body)
        cleaned = result["response"]&.strip
        # Sanity check - don't accept if too different from original
        if cleaned.nil? || cleaned.empty?
          Rails.logger.warn("TextCleanupService: Empty response from model")
          return text
        end
        if cleaned.length > text.length * 1.5 || cleaned.length < text.length * 0.5
          Rails.logger.warn("TextCleanupService: Response length #{cleaned.length} outside bounds for input #{text.length}")
          return text
        end
        cleaned
      else
        Rails.logger.warn("TextCleanupService: Ollama error #{response.code} - #{response.body}")
        text
      end
    rescue => e
      Rails.logger.error("TextCleanupService: #{e.class} - #{e.message}")
      text
    end
  end
end
