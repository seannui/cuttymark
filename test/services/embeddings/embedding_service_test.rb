require "test_helper"

class Embeddings::EmbeddingServiceTest < ActiveSupport::TestCase
  setup do
    @transcript = transcripts(:reunion_transcript)
    @fake_embedding = Array.new(768) { 0.1 }
  end

  test "generate_for_transcript returns stats hash with quality-skipped segments" do
    # Use a stub client that always returns an embedding
    client = StubOllamaClient.new(@fake_embedding)
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    stats = service.generate_for_transcript(@transcript)

    assert_kind_of Hash, stats
    assert_includes stats, :embedded
    assert_includes stats, :skipped_quality
    assert_includes stats, :skipped_blank
    assert_includes stats, :failed
    assert stats[:embedded] > 0, "Expected some segments to be embedded"
    assert stats[:skipped_quality] > 0, "Expected some segments skipped for quality"
    assert_equal 0, stats[:failed]
  end

  test "generate_for_transcript completes the transcript" do
    client = StubOllamaClient.new(@fake_embedding)
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    service.generate_for_transcript(@transcript)
    @transcript.reload

    assert_equal "completed", @transcript.state
  end

  test "generate_for_transcript handles per-segment OllamaClient errors" do
    # Client that fails on first call then succeeds
    client = FailOnceOllamaClient.new(@fake_embedding)
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    stats = service.generate_for_transcript(@transcript)

    # Should have at least 1 failed and 1 embedded (from the valid segments)
    assert stats[:failed] >= 1, "Expected at least one failed segment"
    assert stats[:embedded] >= 1, "Expected at least one embedded segment"
  end

  test "generate_for_transcript re-raises ConnectionError" do
    client = ConnectionErrorClient.new
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    assert_raises Embeddings::OllamaClient::ConnectionError do
      service.generate_for_transcript(@transcript)
    end
  end

  test "generate_for_segment skips low quality text" do
    client = StubOllamaClient.new(@fake_embedding)
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    segment = segments(:garbage_no_spaces)
    segment.update_column(:embedding, nil)

    result = service.generate_for_segment(segment)
    assert_nil result
    assert_equal 0, client.call_count, "Should not have called Ollama for garbage text"
  end

  test "generate_for_segment embeds valid text" do
    client = StubOllamaClient.new(@fake_embedding)
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    segment = segments(:normal_sentence_one)
    segment.update_column(:embedding, nil)

    result = service.generate_for_segment(segment)
    assert_equal @fake_embedding, result
    assert_equal 1, client.call_count
  end

  test "generate_for_segment catches InputTooLargeError" do
    client = InputTooLargeClient.new
    service = Embeddings::EmbeddingService.new(ollama_client: client)

    segment = segments(:normal_sentence_one)
    segment.update_column(:embedding, nil)

    # Should not raise — just returns nil
    result = service.generate_for_segment(segment)
    assert_nil result
  end

  private

  # Test helper: client that always returns a fixed embedding
  class StubOllamaClient
    attr_reader :call_count

    def initialize(embedding)
      @embedding = embedding
      @call_count = 0
    end

    def embed(text)
      return nil if text.blank?
      @call_count += 1
      @embedding
    end

    def health_check = true
  end

  # Test helper: client that fails on first embed call, succeeds after
  class FailOnceOllamaClient
    def initialize(embedding)
      @embedding = embedding
      @failed = false
    end

    def embed(text)
      return nil if text.blank?
      unless @failed
        @failed = true
        raise Embeddings::OllamaClient::Error, "temporary failure"
      end
      @embedding
    end

    def health_check = true
  end

  # Test helper: client that always raises ConnectionError
  class ConnectionErrorClient
    def embed(_text)
      raise Embeddings::OllamaClient::ConnectionError, "connection refused"
    end

    def health_check = false
  end

  # Test helper: client that always raises InputTooLargeError
  class InputTooLargeClient
    def embed(_text)
      raise Embeddings::OllamaClient::InputTooLargeError, "input too large"
    end

    def health_check = true
  end
end
