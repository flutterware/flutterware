/// Reduces a SQL statement to its shape, so queries differing only in their
/// literals group together.
///
/// This is what makes N+1 detection possible at all — the queries of an N+1
/// differ *precisely* in their literals (`user_id = 1`, `= 2`, `= 3`), so
/// exact-string grouping sees N distinct queries. The
/// ruleset is the well-trodden one: literals become `?`, `IN` lists collapse,
/// whitespace folds.
///
/// Runs on the attacher side — the wire carries raw SQL, so these rules can
/// improve with flutterware releases without touching anyone's server.
///
/// Deliberately conservative: under-normalizing splits a group, which costs a
/// missed badge; over-normalizing merges *distinct* queries, which reports a
/// problem that does not exist. Double-quoted tokens are identifiers in
/// standard SQL and are left alone for that reason, even though MySQL would
/// read some of them as strings.
String normalizeSql(String sql) {
  return sql
      // Single-quoted strings, with '' escapes, before numbers — so the
      // digits inside a string are not visited twice.
      .replaceAll(RegExp(r"'(?:[^']|'')*'"), '?')
      // Driver placeholders before bare numbers — the numeric rule would
      // otherwise eat the digit and leave `$?` or `??`. Postgres `$1` and
      // sqlite's numbered `?1` are both already placeholders needing no
      // normalization, and `??` reads as a typo in a title; plain `?` is
      // itself already. `?1` is what `sqlite3`/`sqlite_async` emit.
      .replaceAll(RegExp(r'[\$?]\d+'), '?')
      // Numeric literals. `\b` keeps digits inside identifiers (`user_id2`)
      // untouched: there is no word boundary between `d` and `2`.
      .replaceAll(RegExp(r'\b\d+(\.\d+)?\b'), '?')
      .replaceAll(RegExp(r'\s+'), ' ')
      // `IN (?, ?, ?)` — the list length is exactly the variance to erase.
      // The keyword keeps whatever casing it arrived in.
      .replaceAllMapped(
        RegExp(r'\bin \(\s*\?(?:\s*,\s*\?)*\s*\)', caseSensitive: false),
        (match) => '${match[0]!.substring(0, 2)} (?)',
      )
      .trim();
}
