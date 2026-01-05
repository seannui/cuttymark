class CreateTranscripts < ActiveRecord::Migration[8.1]
  def change
    create_table :transcripts do |t|
      t.references :video, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :engine, default: "whisper"
      t.text :raw_text
      t.text :error_message

      t.timestamps
    end

    add_index :transcripts, :status
    add_index :transcripts, [ :video_id, :status ]
  end
end
