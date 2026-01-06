require "socket"
require "net/http"
require "json"

module Transcription
  class WhisperClient < BaseClient
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 3333

    # Whisper parameters to reduce hallucinations
    DEFAULT_TEMPERATURE = 0.0
    DEFAULT_NO_SPEECH_THRESHOLD = 0.6
    DEFAULT_COMPRESSION_RATIO_THRESHOLD = 2.4

    def initialize(host: nil, port: nil)
      @host = host || ENV.fetch("WHISPER_HOST", DEFAULT_HOST)
      @port = port || ENV.fetch("WHISPER_PORT", DEFAULT_PORT).to_i
    end

    def engine_name
      "whisper"
    end

    def transcribe(audio_path, language: "en", word_timestamps: true, suppress_hallucinations: true, **_options)
      raise ArgumentError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      uri = URI("http://#{@host}:#{@port}/inference")

      request = Net::HTTP::Post.new(uri)
      form_data = [
        ["file", File.open(audio_path, "rb")],
        ["response_format", "verbose_json"],
        ["language", language],
        ["word_timestamps", word_timestamps.to_s],
        ["temperature", DEFAULT_TEMPERATURE.to_s]
      ]

      # Add hallucination suppression parameters
      if suppress_hallucinations
        form_data += [
          ["no_speech_threshold", DEFAULT_NO_SPEECH_THRESHOLD.to_s],
          ["compression_ratio_threshold", DEFAULT_COMPRESSION_RATIO_THRESHOLD.to_s],
          ["condition_on_previous_text", "false"]  # Prevents repetition loops
        ]
      end

      request.set_form(form_data, "multipart/form-data")

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 3600, open_timeout: 30) do |http|
        http.request(request)
      end

      handle_response(response)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise ConnectionError, "Cannot connect to Whisper server at #{@host}:#{@port}. Is it running? Error: #{e.message}"
    rescue Net::ReadTimeout => e
      raise TranscriptionError, "Transcription timed out: #{e.message}"
    end

    def health_check
      # whisper.cpp server doesn't have a /health endpoint, so we just check if the port is open
      Socket.tcp(@host, @port, connect_timeout: 5) { true }
    rescue StandardError
      false
    end

    private

    def handle_response(response)
      case response
      when Net::HTTPSuccess
        parse_response(response.body)
      when Net::HTTPBadRequest
        raise TranscriptionError, "Bad request: #{response.body}"
      when Net::HTTPServerError
        raise TranscriptionError, "Server error: #{response.body}"
      else
        raise TranscriptionError, "Unexpected response: #{response.code} - #{response.body}"
      end
    end

    def parse_response(body)
      data = JSON.parse(body)

      Result.new(
        text: data["text"]&.strip,
        language: data["language"],
        duration: data["duration"],
        segments: parse_segments(data["segments"] || []),
        words: parse_words(data)
      )
    end

    def parse_segments(segments)
      segments.map do |seg|
        SegmentData.new(
          start_time: seg["start"],
          end_time: seg["end"],
          text: seg["text"]&.strip,
          confidence: seg["confidence"] || seg["avg_logprob"]&.then { |lp| Math.exp(lp) },
          speaker: nil  # Whisper doesn't provide speaker diarization
        )
      end
    end

    def parse_words(data)
      words = []

      # whisper.cpp returns words nested in segments
      (data["segments"] || []).each do |segment|
        (segment["words"] || []).each do |word|
          words << WordData.new(
            start_time: word["start"],
            end_time: word["end"],
            text: word["word"]&.strip,
            confidence: word["probability"],
            speaker: nil  # Whisper doesn't provide speaker diarization
          )
        end
      end

      words
    end
  end
end
