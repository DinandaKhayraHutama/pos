<?php

declare(strict_types=1);

namespace App\Domain\Sync;

use Illuminate\Database\Eloquent\Model;

/**
 * Answers "what changed after this number?" for one entity.
 *
 * Deliberately dumb: order by `sync_seq`, take a page, report where the page
 * ended. All the correctness lives in how that number was allocated (see
 * {@see SyncCursor}) rather than here.
 *
 * Tenant filtering is NOT applied here and must not be — every model carries
 * `BelongsToTenant`, so the global scope has already narrowed the query to the
 * device's merchant before this class sees it. A second, hand-written filter
 * would be a place to forget.
 */
class CataloguePuller
{
    public const MAX_LIMIT = 500;

    public const DEFAULT_LIMIT = 200;

    /**
     * @return array{rows: list<array<string, mixed>>, next_seq: int, has_more: bool}
     */
    public function pull(string $entity, int $afterSeq, int $limit): array
    {
        $limit = max(1, min($limit, self::MAX_LIMIT));

        /** @var class-string<Model> $model */
        $model = SyncRegistry::modelFor($entity);
        $columns = SyncRegistry::columnsFor($entity);

        $rows = $model::query()
            // Tombstones are the point of a delta feed — a device only learns a
            // row was deleted by receiving the deletion.
            ->withTombstones()
            ->where('sync_seq', '>', $afterSeq)
            ->orderBy('sync_seq')
            // One extra row, purely to answer has_more without a COUNT over the
            // whole remaining tail.
            ->limit($limit + 1)
            ->get($columns);

        $hasMore = $rows->count() > $limit;
        $page = $hasMore ? $rows->take($limit) : $rows;

        return [
            'rows' => $page->map(fn (Model $row): array => $this->present($row, $columns))->values()->all(),
            // The cursor the device stores. Falls back to what it sent when the
            // page is empty, so an idle poll never rewinds anyone.
            'next_seq' => (int) ($page->last()?->getAttribute('sync_seq') ?? $afterSeq),
            'has_more' => $hasMore,
        ];
    }

    /**
     * @param  list<string>  $columns
     * @return array<string, mixed>
     */
    private function present(Model $row, array $columns): array
    {
        $out = [];
        foreach ($columns as $column) {
            $value = $row->getAttribute($column);
            $out[$column] = $column === 'deleted_at' && $value !== null
                ? $value->toIso8601String()
                : $value;
        }

        return $out;
    }
}
