class CreateSearchQueries < ActiveRecord::Migration[8.1]
  def change
    create_table :search_queries do |t|
      t.references :project, null: false, foreign_key: true
      t.text :query_text, null: false
      t.string :match_type, null: false, default: "semantic"
      # nomic-embed-text produces 768-dimensional embeddings
      t.vector :query_embedding, limit: 768

      t.timestamps
    end

    add_index :search_queries, :match_type
  end
end
