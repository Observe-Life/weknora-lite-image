#!/usr/bin/env python3
"""
修复 WeKnora Lite（SQLite）下 wiki 仓库的 PostgreSQL 专用 SQL。

上游 internal/application/repository/wiki_page.go 里已经有 wikiDialect()
方言判断（category_path 那处就用了），但以下 4 处漏用，导致 SQLite 下
直接报 "unrecognized token: @"：

  1. List()                  —— to_tsvector / plainto_tsquery（PG 全文检索）
  2. ListBySourceRef()       —— source_refs @> ?::jsonb
  3. ListSlugsBySourceRef()  —— source_refs @> ?::jsonb
  4. ListBySourceRefs 批量条件 —— source_refs @> ?::jsonb

影响：删除文档时 wiki 引用清理失败（残留孤儿页面）、wiki 来源追踪失败、
      Wiki 搜索框直接报错。

用法：在 WeKnora 源码根目录执行  python3 fix-wiki-sqlite.py
任一处匹配数不等于 1 就退出并报错，绝不静默跳过。
"""
import sys
import pathlib

TARGET = pathlib.Path("internal/application/repository/wiki_page.go")

# ---------------------------------------------------------------------------
# ① List()：PG 全文检索 → SQLite 退化为子串匹配
# ---------------------------------------------------------------------------
OLD_1 = '''	if req.Query != "" {
		// Use PostgreSQL full-text search + ILIKE for aliases
		query = query.Where(
			"(to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(content, '')) @@ plainto_tsquery('simple', ?) OR aliases::text ILIKE ?)",
			req.Query,
			"%"+req.Query+"%",
		)
	}'''

NEW_1 = '''	if req.Query != "" {
		switch r.wikiDialect() {
		case "postgres":
			// Use PostgreSQL full-text search + ILIKE for aliases
			query = query.Where(
				"(to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(content, '')) @@ plainto_tsquery('simple', ?) OR aliases::text ILIKE ?)",
				req.Query,
				"%"+req.Query+"%",
			)
		default:
			// SQLite has no tsvector/tsquery: fall back to substring matching
			// over the same three fields so the Wiki search box keeps working.
			like := "%" + req.Query + "%"
			query = query.Where(
				"(title LIKE ? OR content LIKE ? OR CAST(aliases AS TEXT) LIKE ?)",
				like, like, like,
			)
		}
	}'''

# ---------------------------------------------------------------------------
# ② ListBySourceRef()
# ---------------------------------------------------------------------------
OLD_2 = '''	var pages []*types.WikiPage
	if err := r.db.WithContext(ctx).
		Where("knowledge_base_id = ? AND (source_refs @> ?::jsonb OR source_refs::text LIKE ?)",
			kbID,
			string(needle),
			likePattern,
		).
		Find(&pages).Error; err != nil {'''

NEW_2 = '''	// Postgres stores source_refs as jsonb and can use the containment operator;
	// SQLite stores JSON as TEXT, so match the serialized text instead. Without
	// this branch the predicate is a syntax error on SQLite
	// ("unrecognized token: @"), which silently broke wiki cleanup on delete.
	refQuery := r.db.WithContext(ctx).Where("knowledge_base_id = ?", kbID)
	switch r.wikiDialect() {
	case "postgres":
		refQuery = refQuery.Where(
			"(source_refs @> ?::jsonb OR source_refs::text LIKE ?)",
			string(needle), likePattern)
	default:
		exactPattern := "%" + escapeLikePattern(string(needle)) + "%"
		refQuery = refQuery.Where(
			"(CAST(source_refs AS TEXT) LIKE ? OR CAST(source_refs AS TEXT) LIKE ?)",
			exactPattern, likePattern)
	}

	var pages []*types.WikiPage
	if err := refQuery.Find(&pages).Error; err != nil {'''

# ---------------------------------------------------------------------------
# ③ ListSlugsBySourceRef()
# ---------------------------------------------------------------------------
OLD_3 = '''	var slugs []string
	if err := r.db.WithContext(ctx).
		Model(&types.WikiPage{}).
		Where("knowledge_base_id = ? AND (source_refs @> ?::jsonb OR source_refs::text LIKE ?)",
			kbID,
			string(needle),
			likePattern,
		).
		Pluck("slug", &slugs).Error; err != nil {
		return nil, err'''

NEW_3 = '''	// Same dialect split as ListBySourceRef — see the comment there.
	refQuery := r.db.WithContext(ctx).
		Model(&types.WikiPage{}).
		Where("knowledge_base_id = ?", kbID)
	switch r.wikiDialect() {
	case "postgres":
		refQuery = refQuery.Where(
			"(source_refs @> ?::jsonb OR source_refs::text LIKE ?)",
			string(needle), likePattern)
	default:
		exactPattern := "%" + escapeLikePattern(string(needle)) + "%"
		refQuery = refQuery.Where(
			"(CAST(source_refs AS TEXT) LIKE ? OR CAST(source_refs AS TEXT) LIKE ?)",
			exactPattern, likePattern)
	}

	var slugs []string
	if err := refQuery.Pluck("slug", &slugs).Error; err != nil {
		return nil, err'''

# ---------------------------------------------------------------------------
# ④ 批量来源查询的 OR 条件构建
# ---------------------------------------------------------------------------
OLD_4 = '''		clauses = append(clauses, "source_refs @> ?::jsonb")
		args = append(args, string(needle))

		prefix, err := json.Marshal(kid + "|")
		if err != nil {
			return nil, fmt.Errorf("marshal kid prefix: %w", err)
		}
		prefixStr := string(prefix)
		if len(prefixStr) >= 2 && prefixStr[len(prefixStr)-1] == '"' {
			prefixStr = prefixStr[:len(prefixStr)-1]
		}
		clauses = append(clauses, "source_refs::text LIKE ?")
		args = append(args, "%"+escapeLikePattern(prefixStr)+"%")'''

NEW_4 = '''		prefix, err := json.Marshal(kid + "|")
		if err != nil {
			return nil, fmt.Errorf("marshal kid prefix: %w", err)
		}
		prefixStr := string(prefix)
		if len(prefixStr) >= 2 && prefixStr[len(prefixStr)-1] == '"' {
			prefixStr = prefixStr[:len(prefixStr)-1]
		}
		if r.wikiDialect() == "postgres" {
			clauses = append(clauses, "source_refs @> ?::jsonb")
			args = append(args, string(needle))
			clauses = append(clauses, "source_refs::text LIKE ?")
			args = append(args, "%"+escapeLikePattern(prefixStr)+"%")
		} else {
			// SQLite: match the serialized JSON text for both the exact
			// ["id"] form and the ["id|title" prefix form.
			clauses = append(clauses, "CAST(source_refs AS TEXT) LIKE ?")
			args = append(args, "%"+escapeLikePattern(string(needle))+"%")
			clauses = append(clauses, "CAST(source_refs AS TEXT) LIKE ?")
			args = append(args, "%"+escapeLikePattern(prefixStr)+"%")
		}'''

PATCHES = [
    ("List() 全文检索", OLD_1, NEW_1),
    ("ListBySourceRef()", OLD_2, NEW_2),
    ("ListSlugsBySourceRef()", OLD_3, NEW_3),
    ("批量来源条件构建", OLD_4, NEW_4),
]


def main() -> int:
    if not TARGET.exists():
        print("错误：找不到 %s（请在 WeKnora 源码根目录执行）" % TARGET, file=sys.stderr)
        return 1

    src = TARGET.read_text(encoding="utf-8")
    original = src

    for name, old, new in PATCHES:
        n = src.count(old)
        if n != 1:
            print("错误：%s 期望匹配 1 处，实际匹配 %d 处。"
                  "上游代码可能已变动，请重新核对补丁。" % (name, n), file=sys.stderr)
            return 1
        src = src.replace(old, new)
        print("  已修补：%s" % name)

    if src == original:
        print("错误：文件内容未发生变化。", file=sys.stderr)
        return 1

    TARGET.write_text(src, encoding="utf-8")
    print("wiki SQLite 方言补丁应用成功：%s" % TARGET)
    return 0


if __name__ == "__main__":
    sys.exit(main())
