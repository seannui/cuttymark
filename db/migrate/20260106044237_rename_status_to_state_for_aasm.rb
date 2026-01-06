class RenameStatusToStateForAasm < ActiveRecord::Migration[8.1]
  def change
    rename_column :videos, :status, :state
    rename_column :transcripts, :status, :state
    rename_column :clips, :status, :state
  end
end
