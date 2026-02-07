class AddSearchVectorToTranscripts < ActiveRecord::Migration[8.1]
  def up
    add_column :transcripts, :search_vector, :tsvector

    add_index :transcripts, :search_vector, using: :gin, name: "index_transcripts_on_search_vector"

    # Create trigger function to auto-update search_vector when raw_text changes
    execute <<-SQL
      CREATE FUNCTION transcripts_search_vector_update() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector := to_tsvector('english', COALESCE(NEW.raw_text, ''));
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<-SQL
      CREATE TRIGGER transcripts_search_vector_trigger
      BEFORE INSERT OR UPDATE OF raw_text ON transcripts
      FOR EACH ROW EXECUTE FUNCTION transcripts_search_vector_update();
    SQL

    # Backfill existing transcripts
    execute <<-SQL
      UPDATE transcripts
      SET search_vector = to_tsvector('english', COALESCE(raw_text, ''))
      WHERE raw_text IS NOT NULL;
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS transcripts_search_vector_trigger ON transcripts"
    execute "DROP FUNCTION IF EXISTS transcripts_search_vector_update()"
    remove_index :transcripts, name: "index_transcripts_on_search_vector", if_exists: true
    remove_column :transcripts, :search_vector
  end
end
