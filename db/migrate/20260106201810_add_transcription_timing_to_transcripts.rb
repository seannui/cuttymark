class AddTranscriptionTimingToTranscripts < ActiveRecord::Migration[8.1]
  def change
    add_column :transcripts, :transcription_started_at, :datetime
    add_column :transcripts, :transcription_completed_at, :datetime
  end
end
