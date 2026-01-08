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

    # Chunked transcription settings to avoid hallucinations on long audio
    CHUNK_DURATION = 120  # 2 minutes per chunk
    CHUNK_OVERLAP = 3     # 3 second overlap to catch word boundaries
    LONG_AUDIO_THRESHOLD = 180  # Use chunked mode for audio > 3 minutes

    def initialize(host: nil, port: nil)
      @host = host || ENV.fetch("WHISPER_HOST", DEFAULT_HOST)
      @port = port || ENV.fetch("WHISPER_PORT", DEFAULT_PORT).to_i
      @ffmpeg = VideoProcessing::FfmpegClient.new
    end

    def engine_name
      "whisper"
    end

    def transcribe(audio_path, language: "en", word_timestamps: true, suppress_hallucinations: true, **_options)
      raise ArgumentError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      # Get audio duration to decide on chunking
      audio_duration = @ffmpeg.get_audio_duration(audio_path)

      if audio_duration > LONG_AUDIO_THRESHOLD
        Rails.logger.info("Long audio (#{audio_duration.round(0)}s) - using chunked transcription")
        transcribe_chunked(audio_path, audio_duration, language: language, word_timestamps: word_timestamps,
                                                       suppress_hallucinations: suppress_hallucinations)
      else
        Rails.logger.info("Short audio (#{audio_duration.round(0)}s) - single request")
        transcribe_single(audio_path, language: language, word_timestamps: word_timestamps,
                                      suppress_hallucinations: suppress_hallucinations)
      end
    end

    MAX_RETRIES = 3
    RETRY_DELAY = 2  # seconds

    def transcribe_single(audio_path, language: "en", word_timestamps: true, suppress_hallucinations: true)
      raise ArgumentError, "Audio file not found: #{audio_path}" unless File.exist?(audio_path)

      retries = 0
      begin
        uri = URI("http://#{@host}:#{@port}/inference")

        # Read file content to avoid file handle issues on retry
        file_content = File.binread(audio_path)
        file_io = StringIO.new(file_content)
        file_io.define_singleton_method(:path) { audio_path }

        request = Net::HTTP::Post.new(uri)
        form_data = [
          ["file", file_io, { filename: File.basename(audio_path), content_type: "audio/wav" }],
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
      rescue TranscriptionError => e
        # Retry on server errors (like "failed to process audio")
        if e.message.include?("Server error") && retries < MAX_RETRIES
          retries += 1
          Rails.logger.warn("Whisper server error, retrying (#{retries}/#{MAX_RETRIES}): #{e.message}")
          sleep(RETRY_DELAY * retries)
          retry
        end
        raise
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
        if retries < MAX_RETRIES
          retries += 1
          Rails.logger.warn("Connection error, retrying (#{retries}/#{MAX_RETRIES}): #{e.message}")
          sleep(RETRY_DELAY * retries)
          retry
        end
        raise ConnectionError, "Cannot connect to Whisper server at #{@host}:#{@port}. Is it running? Error: #{e.message}"
      rescue Net::ReadTimeout => e
        if retries < MAX_RETRIES
          retries += 1
          Rails.logger.warn("Timeout, retrying (#{retries}/#{MAX_RETRIES}): #{e.message}")
          sleep(RETRY_DELAY * retries)
          retry
        end
        raise TranscriptionError, "Transcription timed out: #{e.message}"
      end
    end

    def transcribe_chunked(audio_path, total_duration, language: "en", word_timestamps: true, suppress_hallucinations: true)
      all_segments = []
      all_words = []
      full_text_parts = []
      detected_language = language

      chunk_start = 0.0
      chunk_index = 0

      while chunk_start < total_duration
        chunk_end = [chunk_start + CHUNK_DURATION, total_duration].min
        actual_duration = chunk_end - chunk_start

        Rails.logger.info("Processing chunk #{chunk_index + 1}: #{format_time(chunk_start)} - #{format_time(chunk_end)}")

        # Extract chunk audio
        chunk_path = extract_audio_chunk(audio_path, chunk_start, actual_duration, chunk_index)

        begin
          # Transcribe chunk
          result = transcribe_single(chunk_path, language: language, word_timestamps: word_timestamps,
                                                 suppress_hallucinations: suppress_hallucinations)

          # Offset timestamps by chunk start time
          offset_segments = result.segments.map do |seg|
            SegmentData.new(
              start_time: seg.start_time + chunk_start,
              end_time: seg.end_time + chunk_start,
              text: seg.text,
              confidence: seg.confidence,
              speaker: seg.speaker
            )
          end

          offset_words = result.words.map do |word|
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
          detected_language = result.language if result.language.present?

          Rails.logger.info("Chunk #{chunk_index + 1}: #{offset_segments.size} segments")
        ensure
          # Clean up chunk file
          File.delete(chunk_path) if File.exist?(chunk_path)
        end

        chunk_index += 1
        chunk_start = chunk_end - CHUNK_OVERLAP
        chunk_start = chunk_end if chunk_start >= total_duration - CHUNK_OVERLAP  # Avoid tiny final chunk
      end

      # Merge overlapping segments (remove duplicates from overlap regions)
      merged_segments = merge_overlapping_segments(all_segments)
      merged_words = merge_overlapping_words(all_words)

      # Filter out hallucinated segments (repeated text)
      filtered_segments = filter_hallucinated_segments(merged_segments)
      filtered_words = filter_hallucinated_words(merged_words)

      Rails.logger.info("Chunked transcription complete: #{filtered_segments.size} segments (#{merged_segments.size - filtered_segments.size} hallucinations removed), #{filtered_words.size} words")

      Result.new(
        text: full_text_parts.join(" "),
        language: detected_language,
        duration: total_duration,
        segments: filtered_segments,
        words: filtered_words
      )
    end

    def health_check
      # whisper.cpp server doesn't have a /health endpoint, so we just check if the port is open
      Socket.tcp(@host, @port, connect_timeout: 5) { true }
    rescue StandardError
      false
    end

    private

    def extract_audio_chunk(audio_path, start_time, duration, chunk_index)
      chunk_dir = Rails.root.join("tmp", "whisper_chunks")
      FileUtils.mkdir_p(chunk_dir)
      chunk_path = chunk_dir.join("chunk_#{chunk_index}.wav").to_s

      @ffmpeg.extract_audio_segment(audio_path, chunk_path, start_time: start_time, duration: duration)
      chunk_path
    end

    def merge_overlapping_segments(segments)
      return segments if segments.empty?

      sorted = segments.sort_by(&:start_time)
      merged = [sorted.first]

      sorted[1..].each do |segment|
        last = merged.last
        # If this segment starts within 1s of the last segment's end, it might be a duplicate
        if segment.start_time < last.end_time - 1
          # Keep the longer/better segment
          merged[-1] = segment if segment.text.length > last.text.length
        else
          merged << segment
        end
      end

      merged
    end

    def merge_overlapping_words(words)
      return words if words.empty?

      sorted = words.sort_by(&:start_time)
      merged = [sorted.first]

      sorted[1..].each do |word|
        last = merged.last
        # Skip words that are too close to the previous word (duplicates from overlap)
        if word.start_time < last.end_time - 0.1
          next
        else
          merged << word
        end
      end

      merged
    end

    # Detect and filter hallucinated segments (same text repeated many times)
    HALLUCINATION_THRESHOLD = 3  # If text appears more than 3 times, it's likely hallucinated

    def filter_hallucinated_segments(segments)
      return segments if segments.empty?

      # Count occurrences of each normalized text
      text_counts = segments.group_by { |s| normalize_for_hallucination_check(s.text) }
                           .transform_values(&:size)

      # Find hallucinated texts (appearing more than threshold times)
      hallucinated_texts = text_counts.select { |_, count| count > HALLUCINATION_THRESHOLD }.keys

      if hallucinated_texts.any?
        Rails.logger.warn("Detected #{hallucinated_texts.size} hallucinated phrases: #{hallucinated_texts.first(3).map { |t| t[0..30] }.join(', ')}...")
      end

      # Filter out all but the first occurrence of hallucinated segments
      seen_hallucinations = Set.new
      segments.select do |segment|
        normalized = normalize_for_hallucination_check(segment.text)
        if hallucinated_texts.include?(normalized)
          # Keep only the first occurrence
          if seen_hallucinations.include?(normalized)
            false
          else
            seen_hallucinations.add(normalized)
            true
          end
        else
          true
        end
      end
    end

    def filter_hallucinated_words(words)
      return words if words.empty?

      # For words, filter out sequences of identical words that appear consecutively
      filtered = []
      consecutive_count = 0
      last_word_text = nil

      words.each do |word|
        normalized = word.text&.strip&.downcase
        if normalized == last_word_text
          consecutive_count += 1
          # Skip if we've seen this word more than 3 times consecutively
          next if consecutive_count > 3
        else
          consecutive_count = 1
          last_word_text = normalized
        end
        filtered << word
      end

      filtered
    end

    def normalize_for_hallucination_check(text)
      # Normalize text for comparison: lowercase, remove extra whitespace, strip punctuation
      text&.downcase&.gsub(/[^\w\s]/, "")&.gsub(/\s+/, " ")&.strip
    end

    def format_time(seconds)
      mins = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      format("%d:%02d", mins, secs)
    end

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

      raw_segments = data["segments"] || []
      segments = parse_segments(raw_segments)

      # Use actual word timestamps from Whisper when available (reliable for short chunks)
      # Fall back to synthetic timing for compatibility
      words = parse_words_from_response(raw_segments)
      words = generate_synthetic_words(segments) if words.empty?

      Result.new(
        text: data["text"]&.strip,
        language: data["language"],
        duration: data["duration"],
        segments: segments,
        words: words
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

    # Extract actual word timestamps from Whisper verbose_json response
    def parse_words_from_response(raw_segments)
      words = []

      raw_segments.each do |seg|
        seg_start = seg["start"] || 0.0
        seg_words = seg["words"] || []

        seg_words.each do |w|
          # Skip if word timestamps seem invalid
          next if w["start"].nil? || w["end"].nil?
          next if w["start"] < 0 || w["end"] < w["start"]

          # Word timestamps may be relative to segment or absolute
          # Check if they need offsetting (if all words start near 0, they're relative)
          word_start = w["start"]
          word_end = w["end"]

          # If the word start is less than segment start, it's relative - add offset
          if word_start < seg_start && seg_start > 0
            word_start += seg_start
            word_end += seg_start
          end

          words << WordData.new(
            start_time: word_start,
            end_time: word_end,
            text: w["word"]&.strip,
            confidence: w["probability"] || 0.9,
            speaker: nil
          )
        end
      end

      words
    end

    # Generate synthetic word timings by distributing segment duration across words
    def generate_synthetic_words(segments)
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
            confidence: segment.confidence || 0.9,
            speaker: nil
          )
        end
      end

      words
    end
  end
end
