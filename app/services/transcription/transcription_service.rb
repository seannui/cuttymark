module Transcription
  class TranscriptionService
    class Error < StandardError; end

    def initialize(whisper_client: nil, ffmpeg_client: nil)
      @whisper = whisper_client || WhisperClient.new
      @ffmpeg = ffmpeg_client || VideoProcessing::FfmpegClient.new
    end

    def transcribe(video)
      Rails.logger.info("Starting transcription for video: #{video.filename} (#{video.id})")

      # Create or find transcript record
      transcript = video.transcript || video.create_transcript!
      transcript.update!(status: :processing, engine: "whisper")

      begin
        # Extract audio
        audio_path = extract_audio(video)
        Rails.logger.info("Audio extracted to: #{audio_path}")

        # Transcribe with Whisper
        transcript.update!(status: :processing)
        result = @whisper.transcribe(audio_path, word_timestamps: true)
        Rails.logger.info("Whisper returned #{result.words.size} words")

        # Build segments
        transcript.update!(status: :segmenting)
        builder = SegmentBuilder.new(transcript)
        counts = builder.build_from_whisper_result(result)
        Rails.logger.info("Created segments: #{counts}")

        # Mark complete
        transcript.update!(status: :completed)
        video.update!(status: :transcribed)

        # Clean up audio file
        cleanup_audio(audio_path)

        transcript
      rescue WhisperClient::Error => e
        handle_error(transcript, video, "Whisper error: #{e.message}")
        raise Error, e.message
      rescue VideoProcessing::FfmpegClient::Error => e
        handle_error(transcript, video, "FFmpeg error: #{e.message}")
        raise Error, e.message
      rescue StandardError => e
        handle_error(transcript, video, "Unexpected error: #{e.message}")
        raise
      end
    end

    def whisper_available?
      @whisper.health_check
    end

    private

    def extract_audio(video)
      source_path = video.playable_path
      raise Error, "Video file not found: #{source_path}" unless File.exist?(source_path)

      # Use a cached audio path based on video ID
      cached_audio_path = audio_cache_path(video)

      # Check if cached audio exists and is newer than source video
      if File.exist?(cached_audio_path) && File.mtime(cached_audio_path) >= File.mtime(source_path)
        Rails.logger.info("Using cached audio file: #{cached_audio_path}")
        return cached_audio_path
      end

      Rails.logger.info("Extracting audio from video...")
      @ffmpeg.extract_audio(
        source_path,
        output_path: cached_audio_path,
        format: "wav",
        sample_rate: 16000,  # Whisper expects 16kHz
        channels: 1          # Mono
      )
    end

    def audio_cache_path(video)
      cache_dir = Rails.root.join("storage", "audio_cache")
      FileUtils.mkdir_p(cache_dir)
      cache_dir.join("video_#{video.id}.wav").to_s
    end

    def cleanup_audio(audio_path)
      # Keep cached audio files for reuse
      Rails.logger.debug("Keeping cached audio file: #{audio_path}")
    end

    def handle_error(transcript, video, message)
      Rails.logger.error(message)
      transcript.update!(status: :failed, error_message: message)
      video.update!(status: :error)
    end
  end
end
