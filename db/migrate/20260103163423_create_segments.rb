class CreateSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :segments do |t|
      t.references :transcript, null: false, foreign_key: true
      t.text :text, null: false
      t.float :start_time, null: false
      t.float :end_time, null: false
      t.float :confidence
      t.string :segment_type, null: false, default: "word"
      t.string :speaker
      # nomic-embed-text produces 768-dimensional embeddings
      t.vector :embedding, limit: 768

      t.timestamps
    end

    add_index :segments, :segment_type
    add_index :segments, [ :transcript_id, :start_time ]
    add_index :segments, [ :transcript_id, :segment_type ]
  end
end
