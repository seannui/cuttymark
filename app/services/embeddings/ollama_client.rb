require "socket"
require "net/http"
require "json"

module Embeddings
  class OllamaClient
    class Error < StandardError; end
    class ConnectionError < Error; end
    class ModelError < Error; end

    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 11434
    DEFAULT_MODEL = "nomic-embed-text"

    def initialize(host: nil, port: nil, model: nil)
      @host = host || ENV.fetch("OLLAMA_HOST", DEFAULT_HOST)
      @port = port || ENV.fetch("OLLAMA_PORT", DEFAULT_PORT).to_i
      @model = model || ENV.fetch("OLLAMA_EMBED_MODEL", DEFAULT_MODEL)
    end

    def embed(text)
      return nil if text.blank?

      embed_batch([text]).first
    end

    def embed_batch(texts, batch_size: 32)
      return [] if texts.empty?

      results = []
      texts.each_slice(batch_size) do |batch|
        batch.each do |text|
          results << generate_embedding(text)
        end
      end
      results
    end

    def health_check
      # Just check if Ollama is reachable
      Socket.tcp(@host, @port, connect_timeout: 5) { true }
    rescue StandardError
      false
    end

    def model_available?
      health_check
    end

    private

    def generate_embedding(text)
      uri = URI("http://#{@host}:#{@port}/api/embed")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate({
        model: @model,
        input: text
      })

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 120, open_timeout: 30) do |http|
        http.request(request)
      end

      handle_response(response)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise ConnectionError, "Cannot connect to Ollama at #{@host}:#{@port}. Is it running? Error: #{e.message}"
    rescue Net::ReadTimeout => e
      raise Error, "Embedding request timed out: #{e.message}"
    end

    def handle_response(response)
      case response
      when Net::HTTPSuccess
        data = JSON.parse(response.body)
        # Ollama returns embeddings array - we want the first one
        embeddings = data["embeddings"] || [data["embedding"]]
        embeddings&.first
      when Net::HTTPNotFound
        raise ModelError, "Model '#{@model}' not found. Run: ollama pull #{@model}"
      else
        raise Error, "Ollama error: #{response.code} - #{response.body}"
      end
    end
  end
end
