module Transcription
  class BaseClient
    class Error < StandardError; end
    class ConnectionError < Error; end
    class TranscriptionError < Error; end

    # Common result structures shared by all transcription engines
    Result = Struct.new(:text, :language, :duration, :segments, :words, keyword_init: true)
    SegmentData = Struct.new(:start_time, :end_time, :text, :confidence, :speaker, keyword_init: true)
    WordData = Struct.new(:start_time, :end_time, :text, :confidence, :speaker, keyword_init: true)

    def transcribe(audio_path, **options)
      raise NotImplementedError, "#{self.class} must implement #transcribe"
    end

    def health_check
      raise NotImplementedError, "#{self.class} must implement #health_check"
    end

    def engine_name
      raise NotImplementedError, "#{self.class} must implement #engine_name"
    end
  end
end
