class AddThumbnailPathToClips < ActiveRecord::Migration[8.1]
  def change
    add_column :clips, :thumbnail_path, :string
  end
end
