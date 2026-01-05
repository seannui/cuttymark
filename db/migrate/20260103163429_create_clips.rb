class CreateClips < ActiveRecord::Migration[8.1]
  def change
    create_table :clips do |t|
      t.references :video, null: false, foreign_key: true
      t.references :match, foreign_key: true  # Optional - clips can be manually created
      t.string :title
      t.float :start_time, null: false
      t.float :end_time, null: false
      t.string :status, null: false, default: "defined"
      t.string :export_path
      t.text :notes

      t.timestamps
    end

    add_index :clips, :status
    add_index :clips, [ :video_id, :start_time ]
  end
end
