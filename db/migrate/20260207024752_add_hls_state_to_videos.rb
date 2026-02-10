class AddHlsStateToVideos < ActiveRecord::Migration[8.1]
  def change
    add_column :videos, :hls_state, :string
    add_index :videos, :hls_state
  end
end
