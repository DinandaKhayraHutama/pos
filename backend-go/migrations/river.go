package migrations

import (
	"context"
	"database/sql"

	"github.com/pressly/goose/v3"
	"github.com/riverqueue/river/riverdriver/riverdatabasesql"
	"github.com/riverqueue/river/rivermigrate"
)

// River owns its versioned SQL. Its enum additions must commit between versions,
// so this is a restartable nontransactional goose step under the deploy lock.
func GoMigrations() []*goose.Migration {
	return []*goose.Migration{goose.NewGoMigration(20260913000013,
		&goose.GoFunc{RunDB: func(ctx context.Context, db *sql.DB) error {
			if _, err := db.ExecContext(ctx, "CREATE SCHEMA IF NOT EXISTS jobs"); err != nil {
				return err
			}
			m, err := rivermigrate.New(riverdatabasesql.New(db), &rivermigrate.Config{Schema: "jobs"})
			if err != nil {
				return err
			}
			if _, err := m.Migrate(ctx, rivermigrate.DirectionUp, nil); err != nil {
				return err
			}
			_, err = db.ExecContext(ctx, `
				GRANT USAGE ON SCHEMA jobs TO justclick_app;
				GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA jobs TO justclick_app;
				GRANT USAGE ON ALL SEQUENCES IN SCHEMA jobs TO justclick_app;
				ALTER TABLE jobs.river_job ENABLE ROW LEVEL SECURITY;
				ALTER TABLE jobs.river_job FORCE ROW LEVEL SECURITY;
				DROP POLICY IF EXISTS tenant_jobs ON jobs.river_job;
				CREATE POLICY tenant_jobs ON jobs.river_job
				 USING (args->>'tenant_id' = app.current_tenant_id()::text)
				 WITH CHECK (args->>'tenant_id' = app.current_tenant_id()::text)`)
			return err
		}}, &goose.GoFunc{RunTx: func(ctx context.Context, tx *sql.Tx) error {
			_, err := tx.ExecContext(ctx, "DROP SCHEMA jobs CASCADE")
			return err
		}})}
}
