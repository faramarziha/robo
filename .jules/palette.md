## 2026-08-04 - Telegram Inline Keyboard Pagination Improvements

**Learning:** When dealing with pagination in Telegram inline keyboards across multiple lists (e.g. users, agents, invoices), the count query `numpage` must explicitly match the filter query to prevent blank pages. Furthermore, the UI lacks state context when paging without a visual indicator, and empty pagination controls are misleading.

**Action:** Ensure all pagination lists use a filtered `COUNT` query. Always inject a non-clickable indicator (e.g., `📄 $page / $total_pages`) between the Previous and Next buttons. Hide the entire pagination row if `$total_pages <= 1`, while ensuring a persistent 'Back' button remains on every view.
