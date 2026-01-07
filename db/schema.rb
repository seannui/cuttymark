# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_01_07_034508) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "vector"

  create_table "clips", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "end_time", null: false
    t.string "export_path"
    t.bigint "match_id"
    t.text "notes"
    t.float "start_time", null: false
    t.string "state", default: "defined", null: false
    t.string "thumbnail_path"
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "video_id", null: false
    t.index ["match_id"], name: "index_clips_on_match_id"
    t.index ["state"], name: "index_clips_on_state"
    t.index ["video_id", "start_time"], name: "index_clips_on_video_id_and_start_time"
    t.index ["video_id"], name: "index_clips_on_video_id"
  end

  create_table "matches", force: :cascade do |t|
    t.text "context_text"
    t.datetime "created_at", null: false
    t.float "relevance_score"
    t.bigint "search_query_id", null: false
    t.bigint "segment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["search_query_id"], name: "index_matches_on_search_query_id"
    t.index ["segment_id"], name: "index_matches_on_segment_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_projects_on_name"
  end

  create_table "search_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "match_type", default: "semantic", null: false
    t.bigint "project_id", null: false
    t.vector "query_embedding", limit: 768
    t.text "query_text", null: false
    t.datetime "updated_at", null: false
    t.index ["match_type"], name: "index_search_queries_on_match_type"
    t.index ["project_id"], name: "index_search_queries_on_project_id"
  end

  create_table "segments", force: :cascade do |t|
    t.float "confidence"
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 768
    t.float "end_time", null: false
    t.string "segment_type", default: "word", null: false
    t.string "speaker"
    t.float "start_time", null: false
    t.text "text", null: false
    t.bigint "transcript_id", null: false
    t.datetime "updated_at", null: false
    t.index ["segment_type"], name: "index_segments_on_segment_type"
    t.index ["transcript_id", "segment_type"], name: "index_segments_on_transcript_id_and_segment_type"
    t.index ["transcript_id", "start_time"], name: "index_segments_on_transcript_id_and_start_time"
    t.index ["transcript_id"], name: "index_segments_on_transcript_id"
  end

  create_table "transcripts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "engine", default: "whisper"
    t.text "error_message"
    t.text "raw_text"
    t.string "state", default: "pending", null: false
    t.datetime "transcription_completed_at"
    t.datetime "transcription_started_at"
    t.datetime "updated_at", null: false
    t.bigint "video_id", null: false
    t.index ["state"], name: "index_transcripts_on_state"
    t.index ["video_id", "state"], name: "index_transcripts_on_video_id_and_state"
    t.index ["video_id"], name: "index_transcripts_on_video_id"
  end

  create_table "videos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.bigint "file_size"
    t.string "filename", null: false
    t.string "format"
    t.jsonb "metadata", default: {}
    t.bigint "project_id", null: false
    t.string "proxy_path"
    t.string "source_path", null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["filename"], name: "index_videos_on_filename"
    t.index ["project_id"], name: "index_videos_on_project_id"
    t.index ["source_path"], name: "index_videos_on_source_path", unique: true
    t.index ["state"], name: "index_videos_on_state"
  end

  add_foreign_key "clips", "matches"
  add_foreign_key "clips", "videos"
  add_foreign_key "matches", "search_queries"
  add_foreign_key "matches", "segments"
  add_foreign_key "search_queries", "projects"
  add_foreign_key "segments", "transcripts"
  add_foreign_key "transcripts", "videos"
  add_foreign_key "videos", "projects"
end
