require "test_helper"

class Embeddings::TextQualityValidatorTest < ActiveSupport::TestCase
  include Embeddings::TextQualityValidator

  test "valid normal text passes" do
    valid, reason = validate_text_quality("We had a great time filming that summer.")
    assert valid
    assert_nil reason
  end

  test "blank text is invalid" do
    valid, reason = validate_text_quality("")
    assert_not valid
    assert_equal "blank", reason

    valid, reason = validate_text_quality(nil)
    assert_not valid
    assert_equal "blank", reason
  end

  test "text exceeding max length is invalid" do
    long_text = "a " * 20_000 # 40,000 chars with spaces
    valid, reason = validate_text_quality(long_text)
    assert_not valid
    assert_match(/too_long/, reason)
  end

  test "text at or under max length is valid" do
    # Use varied words to avoid triggering repetitive content check
    sentences = (1..500).map { |i| "Sentence number #{i} is unique." }
    text = sentences.join(" ")
    assert text.length < 30_000, "Test text should be under max length"
    valid, _reason = validate_text_quality(text)
    assert valid
  end

  test "low space ratio text is invalid" do
    # Fused words with no spaces — typical Whisper hallucination
    fused_text = "Ihadalotoffunwithhim" * 50 # 1000 chars, 0% spaces
    valid, reason = validate_text_quality(fused_text)
    assert_not valid
    assert_match(/low_space_ratio/, reason)
  end

  test "normal text space ratio passes" do
    normal_text = "This is a perfectly normal sentence with lots of spaces. " * 20
    valid, _reason = validate_text_quality(normal_text)
    assert valid
  end

  test "short text skips heuristic checks" do
    # Short text with no spaces — below MIN_LENGTH_FOR_HEURISTICS
    short_fused = "abcdefghij" * 10 # 100 chars, no spaces
    valid, _reason = validate_text_quality(short_fused)
    assert valid
  end

  test "highly repetitive text is invalid" do
    # Use a 3-word phrase to guarantee trigram repetition
    repetitive = (["yes yes yes"] * 300).join(" ")
    valid, reason = validate_text_quality(repetitive)
    assert_not valid
    assert_match(/repetitive_content/, reason)
  end

  test "non-repetitive long text is valid" do
    # Generate text with varied content
    sentences = (1..100).map { |i| "Sentence number #{i} is unique and different from the others." }
    text = sentences.join(" ")
    valid, _reason = validate_text_quality(text)
    assert valid
  end
end
