
## 2024-05-18 - Atomic Refund Operations

**Learning:** When performing financial operations like crediting a user's balance and updating an invoice status, ensuring atomicity is critical to avoid race conditions or incomplete states (e.g., wallet credited but invoice status update failed). Furthermore, re-implementing balance adjustments directly using raw SQL is prone to inconsistency when helper functions like `creditBalance` are available.

**Action:** Always wrap multi-step financial mutations (such as refunds or balance deductions combined with state changes) in a transaction block using the project's `withTransaction` helper. Use existing atomic helpers like `creditBalance` instead of writing raw `UPDATE user SET Balance = ...` queries.
