package main

import "testing"

func TestStatusRowsAtOneOutletHaveDistinctKeys(t *testing.T) {
	a := rowKey(map[string]any{"table_id": "table-a", "outlet_id": "outlet"})
	b := rowKey(map[string]any{"table_id": "table-b", "outlet_id": "outlet"})
	if a == "" || a == b {
		t.Fatal("status identity must include table_id, not just outlet_id")
	}
}
