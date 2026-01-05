class CreateVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :videos do |t|
      t.references :project, null: false, foreign_key: true
      t.string :source_path, null: false
      t.string :proxy_path
      t.string :filename, null: false
      t.float :duration_seconds
      t.string :format
      t.bigint :file_size
      t.string :status, null: false, default: "pending"
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :videos, :source_path, unique: true
    add_index :videos, :status
    add_index :videos, :filename
  end
end
