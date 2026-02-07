class AddModelToTranscripts < ActiveRecord::Migration[8.1]
  def change
    add_column :transcripts, :model, :string
  end
end
