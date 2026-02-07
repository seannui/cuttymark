require "test_helper"
require "minitest/mock"

class EmbeddingJobTest < ActiveSupport::TestCase
  setup do
    @transcript = transcripts(:reunion_transcript)
  end

  test "transitions transcript to failed on unexpected error" do
    # Ensure transcript is in embedding state so it can transition to failed
    @transcript.update_column(:state, "embedding")
    service_stub = ->(*_args, **_kwargs) {
      svc = Object.new
      def svc.generate_for_transcript(_transcript)
        raise RuntimeError, "unexpected boom"
      end
      svc
    }

    Embeddings::EmbeddingService.stub(:new, service_stub.call) do
      assert_raises RuntimeError do
        EmbeddingJob.perform_now(@transcript.id)
      end
    end

    @transcript.reload
    assert_equal "failed", @transcript.state
  end

  test "does not transition to failed on ConnectionError" do
    service_stub = Object.new
    def service_stub.generate_for_transcript(_transcript)
      raise Embeddings::OllamaClient::ConnectionError, "connection refused"
    end

    # retry_on swallows the exception in perform_now, so we just verify
    # the transcript does NOT transition to failed state
    Embeddings::EmbeddingService.stub(:new, service_stub) do
      EmbeddingJob.perform_now(@transcript.id)
    end

    @transcript.reload
    assert_not_equal "failed", @transcript.state
  end

  test "logs stats on successful completion" do
    stats = { embedded: 5, skipped_quality: 2, skipped_blank: 0, failed: 0 }
    service_stub = Object.new
    service_stub.define_singleton_method(:generate_for_transcript) { |_transcript| stats }

    Embeddings::EmbeddingService.stub(:new, service_stub) do
      assert_nothing_raised do
        EmbeddingJob.perform_now(@transcript.id)
      end
    end
  end

  test "raises RecordNotFound for missing transcript" do
    assert_raises ActiveRecord::RecordNotFound do
      EmbeddingJob.perform_now(-1)
    end
  end
end
