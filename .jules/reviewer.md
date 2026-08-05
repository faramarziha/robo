## 2025-02-14 - Replace $pdo->query() with PDO prepared statements

**Learning:** All database queries must use PDO prepared statements (`$pdo->prepare()` and `$stmt->execute()`) instead of raw `$pdo->query()` with string interpolation to prevent SQL injection vulnerabilities.

**Action:** I will find all instances of `$pdo->query()` and replace them with `$pdo->prepare()` and `$stmt->execute()`.
