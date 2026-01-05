class CreateMatches < ActiveRecord::Migration[8.1]
  def change
    create_table :matches do |t|
      t.references :search_query, null: false, foreign_key: true
      t.references :segment, null: false, foreign_key: true
      t.float :relevance_score
      t.text :context_text

      t.timestamps
    end
  end
end
