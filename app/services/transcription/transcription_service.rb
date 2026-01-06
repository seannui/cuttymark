module Transcription
  class TranscriptionService
    class Error < StandardError; end

    # Audio with mean volume below this threshold will be normalized
    LOW_VOLUME_THRESHOLD_DB = -30

    def initialize(whisper_client: nil, ffmpeg_client: nil)
      @whisper = whisper_client || WhisperClient.new
      @ffmpeg = ffmpeg_client || VideoProcessing::FfmpegClient.new
    end

    def transcribe(video, normalize: :auto)
      Rails.logger.info("Starting transcription for video: #{video.filename} (#{video.id})")

      # Transition video to transcribing state
      video.start_transcription! if video.may_start_transcription?

      # Create or find transcript record
      transcript = video.transcript || video.create_transcript!
      transcript.start_processing! if transcript.may_start_processing?
      transcript.update!(engine: "whisper")

      begin
        # Extract audio
        audio_path = extract_audio(video)
        Rails.logger.info("Audio extracted to: #{audio_path}")

        # Check if normalization is needed
        audio_path = maybe_normalize_audio(audio_path, normalize)

        # Transcribe with Whisper
        result = @whisper.transcribe(audio_path, word_timestamps: true)
        Rails.logger.info("Whisper returned #{result.words.size} words")

        # Build segments
        transcript.start_segmenting! if transcript.may_start_segmenting?
        builder = SegmentBuilder.new(transcript)
        counts = builder.build_from_whisper_result(result)
        Rails.logger.info("Created segments: #{counts}")

        # Clean up temporary files
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

    # Normalize audio if needed based on volume analysis
    def maybe_normalize_audio(audio_path, normalize_option)
      case normalize_option
      when true
        normalize_audio(audio_path)
      when false
        audio_path
      when :auto
        mean_volume = @ffmpeg.get_mean_volume(audio_path)
        Rails.logger.info("Audio mean volume: #{mean_volume.round(1)} dB")

        if mean_volume < LOW_VOLUME_THRESHOLD_DB
          Rails.logger.info("Low volume detected (#{mean_volume.round(1)} dB < #{LOW_VOLUME_THRESHOLD_DB} dB), normalizing...")
          normalize_audio(audio_path)
        else
          audio_path
        end
      else
        audio_path
      end
    end

    def normalize_audio(audio_path)
      normalized_path = audio_path.sub(/\.wav$/, "_normalized.wav")
      @ffmpeg.normalize_audio(audio_path, output_path: normalized_path)
      Rails.logger.info("Audio normalized to: #{normalized_path}")
      normalized_path
    end

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
      transcript.fail! if transcript.may_fail?
      transcript.update!(error_message: message)
      video.fail! if video.may_fail?
    end
  end
end
