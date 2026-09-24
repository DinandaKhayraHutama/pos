package customer

// Merge is Fase 2's explicit customer-dedup action: the loser is tombstoned
// and left pointing at the winner, and nothing about either row's orders is
// touched.
//
// Resolution happens at READ time (see, once F2.3 lands, the join a
// purchase-history query does against merged_into_id), never at write time:
// a device offline for a week could otherwise push an order naming a
// customer id that gets merged away before the order ever arrives, and
// rewriting the order to point at the winner would be writing something the
// till never actually sent.

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

var (
	ErrCannotMergeIntoSelf = errors.New("customer: cannot merge a customer into itself")
	// ErrAlreadyMerged is returned for either side already carrying a
	// merged_into_id — re-merging an already-merged row would either extend
	// a chain (which reads would then have to follow more than one hop) or
	// silently no-op. Repoint through the CURRENT winner instead.
	ErrAlreadyMerged = errors.New("customer: already merged; merge through its current winner")
)

// Merge folds loserID into winnerID.
func (s *Service) Merge(ctx context.Context, tenantID, winnerID, loserID string) error {
	if !validation.UUID(winnerID) || !validation.UUID(loserID) {
		return ErrNotFound
	}
	if winnerID == loserID {
		return ErrCannotMergeIntoSelf
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		// Locked in a fixed order (by id, not by role) so two merges racing
		// in opposite directions over the same pair cannot deadlock.
		first, second := winnerID, loserID
		if first > second {
			first, second = second, first
		}
		if err := lockRow(ctx, w.Tx, tenantID, first); err != nil {
			return err
		}
		if err := lockRow(ctx, w.Tx, tenantID, second); err != nil {
			return err
		}

		winnerMerged, err := mergedInto(ctx, w.Tx, tenantID, winnerID)
		if err != nil {
			return err
		}
		if winnerMerged != nil {
			return ErrAlreadyMerged
		}
		loserMerged, err := mergedInto(ctx, w.Tx, tenantID, loserID)
		if err != nil {
			return err
		}
		if loserMerged != nil {
			return ErrAlreadyMerged
		}

		// Path compression: anything already pointing at the loser (from an
		// earlier merge into it) now points straight at the winner, so no
		// reader ever follows more than one hop. merged_into_id is never
		// published to a till, so this touches no sync_seq.
		if _, err := w.Tx.Exec(ctx, `
			UPDATE customers SET merged_into_id = $3
			WHERE tenant_id = $1 AND merged_into_id = $2`, tenantID, loserID, winnerID); err != nil {
			return err
		}

		seq, err := w.Seq(ctx, "customers")
		if err != nil {
			return err
		}

		tag, err := w.Tx.Exec(ctx, `
			UPDATE customers
			SET merged_into_id = $3, active = false, deleted_at = now(), sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`,
			tenantID, loserID, winnerID, seq)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}

		return nil
	})
}

func lockRow(ctx context.Context, tx pgx.Tx, tenantID, id string) error {
	var found bool
	err := tx.QueryRow(ctx,
		`SELECT true FROM customers WHERE tenant_id = $1 AND id = $2 FOR UPDATE`,
		tenantID, id).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

func mergedInto(ctx context.Context, tx pgx.Tx, tenantID, id string) (*string, error) {
	var v *string
	err := tx.QueryRow(ctx,
		`SELECT merged_into_id::text FROM customers WHERE tenant_id = $1 AND id = $2`,
		tenantID, id).Scan(&v)
	return v, err
}
