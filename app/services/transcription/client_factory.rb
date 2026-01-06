module Transcription
  class ClientFactory
    ENGINES = {
      whisper: WhisperClient,
      gemini: GeminiClient
    }.freeze

    class << self
      def create(engine = nil, **options)
        engine ||= default_engine
        engine = engine.to_sym

        unless ENGINES.key?(engine)
          raise ArgumentError, "Unknown transcription engine: #{engine}. Available: #{ENGINES.keys.join(', ')}"
        end

        ENGINES[engine].new(**options)
      end

      def default_engine
        ENV.fetch("TRANSCRIPTION_ENGINE", "whisper").to_sym
      end

      def available_engines
        ENGINES.keys
      end

      def engine_available?(engine)
        client = create(engine)
        client.health_check
      rescue ArgumentError, BaseClient::Error
        false
      end
    end
  end
end
