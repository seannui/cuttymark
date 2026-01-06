class RemoveSolidQueueTablesFromPostgres < ActiveRecord::Migration[8.1]
  def up
    # Drop execution tables first (they reference solid_queue_jobs)
    drop_table :solid_queue_blocked_executions, if_exists: true
    drop_table :solid_queue_claimed_executions, if_exists: true
    drop_table :solid_queue_failed_executions, if_exists: true
    drop_table :solid_queue_ready_executions, if_exists: true
    drop_table :solid_queue_recurring_executions, if_exists: true
    drop_table :solid_queue_scheduled_executions, if_exists: true

    # Drop other tables
    drop_table :solid_queue_recurring_tasks, if_exists: true
    drop_table :solid_queue_semaphores, if_exists: true
    drop_table :solid_queue_pauses, if_exists: true
    drop_table :solid_queue_processes, if_exists: true

    # Drop jobs table last
    drop_table :solid_queue_jobs, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Solid Queue tables now live in SQLite database"
  end
end
