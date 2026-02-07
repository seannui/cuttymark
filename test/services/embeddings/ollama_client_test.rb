require "test_helper"

class Embeddings::OllamaClientTest < ActiveSupport::TestCase
  setup do
    @client = Embeddings::OllamaClient.new(host: "127.0.0.1", port: 11434)
  end

  test "raises InputTooLargeError for text exceeding MAX_INPUT_CHARS" do
    long_text = "a" * 31_000

    assert_raises Embeddings::OllamaClient::InputTooLargeError do
      @client.embed(long_text)
    end
  end

  test "raises InputTooLargeError in embed_batch for oversized text" do
    long_text = "a" * 31_000

    assert_raises Embeddings::OllamaClient::InputTooLargeError do
      @client.embed_batch([long_text])
    end
  end

  test "returns nil for blank text without raising" do
    result = @client.embed("")
    assert_nil result

    result = @client.embed(nil)
    assert_nil result
  end

  test "text under limit does not raise InputTooLargeError" do
    text = "a" * 29_000

    # This will raise a ConnectionError since Ollama isn't running in test,
    # but it should NOT raise InputTooLargeError
    assert_raises Embeddings::OllamaClient::ConnectionError do
      @client.embed(text)
    end
  end

  test "handle_response raises InputTooLargeError for context length error" do
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, "the input length exceeds the context length")

    assert_raises Embeddings::OllamaClient::InputTooLargeError do
      @client.send(:handle_response, response)
    end
  end

  test "handle_response raises generic Error for other 400 errors" do
    response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, "some other bad request error")

    error = assert_raises Embeddings::OllamaClient::Error do
      @client.send(:handle_response, response)
    end
    assert_not_kind_of Embeddings::OllamaClient::InputTooLargeError, error
  end

  test "MAX_INPUT_CHARS is 30000" do
    assert_equal 30_000, Embeddings::OllamaClient::MAX_INPUT_CHARS
  end
end
