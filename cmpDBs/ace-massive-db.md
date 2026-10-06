# `mtree build` fails with "out of memory"

Суть проблемы такая. Merkle tree держится на одном допущении: таблица разрезана на блоки ограниченного размера, и на всех нодах разрезана одинаково. От размера блока зависит всё: память на хеш листа, время пересчёта «грязного» блока, точность diff. Но точно нарезать таблицу по N строк можно только одним способом: пройти все ключи по порядку. На таблице в миллиарды строк это само по себе полный проход. Поэтому возникает соблазн нарезать дешевле, по оценке: по выборке, по статистике.

Оценка даёт верный средний размер блока, но ничего не гарантирует про максимальный. А ломается система именно на максимальном. Расстояния между соседними точками выборки случайны, и самый большой разрыв растёт с числом точек примерно как логарифм от него. На миллионе строк хвост этого распределения не виден: даже самый большой блок помещается в любой лимит. На миллиардах строк и сотнях тысяч блоков редкое событие становится почти неизбежным: где-то обязательно найдётся разрыв в десятки раз больше среднего. Выборка по страницам (SYSTEM) делает хвост ещё тяжелее: точки приходят пачками, и между пачками остаются длинные пустые промежутки.

Сам по себе неравный блок — не ошибка, а только неэффективность. Ошибкой он становится, когда цена обработки блока растёт с его размером без предела. В ACE хеш листа считался от склеенного текста всех строк блока, поэтому память на блок росла линейно и упиралась в жёсткий предел Postgres в 1 GB на значение. Так статистический перекос превратился в отказ. Получается принципиальная пара: приблизительная нарезка плюс неограниченная цена блока. Каждая из двух частей по отдельности безопасна, вместе они рано или поздно ломаются, и чем больше таблица, тем вернее.

Масштаб добавляет и вторую сторону проблемы: построение длится часы, и вероятность сбоя за это время уже не мала. Если построение атомарно (одна транзакция, одна ошибка выбрасывает всё), то большую таблицу можно не построить никогда: каждая попытка дольше и рискованнее предыдущей. К тому же длинная транзакция сама вредит производственной базе: она держит xmin horizon и мешает vacuum.

Отсюда правила для построения Merkle tree на больших данных. Цена блока должна быть ограничена независимо от его размера и ширины строк (хеш из хешей строк). Размер блока должен гарантироваться самим проходом, а не оценкой (оценки годятся только для раздачи работы). Границы определяются один раз и применяются на всех нодах. А построение должно идти частями, которые коммитятся по отдельности, чтобы сбой стоил одной части, а не всей работы.

# Details

1. Где считать строки. Если считать на сервере (row_number() и GROUP BY блока, как в запросе выше), с сервера приходят только границы и хеши, около 380K строк результата. Логика та же — «закончились M строк, начинай новый блок», — только выполняет её Postgres.

2. Один проход — это один длинный запрос. Если пройти всю таблицу одним запросом, мы снова получим многочасовой snapshot, который держит xmin, и потерю всего при сбое. Поэтому проход режется на части (по гистограмме): в каждой части те же «M строк — граница», но запрос короткий, коммит после каждой части, после сбоя продолжаем со следующей. Граница части — принудительная, последний блок в части неполный.

3. Где хранить список границ. Файл на машине с ACE подходит как результат (это тот же формат, что --ranges-file). Но для продолжения после сбоя надёжнее хранить границы в mtree-таблице на опорной ноде с коммитом по частям: если машина с ACE перезапустится, состояние останется в базе.

И один бонус. Другим нодам не обязательно ждать весь список. Как только опорная нода закончила часть k, её границы уже известны, и остальные ноды могут хешировать часть k, пока опорная режет часть k+1. Получается конвейер, и общее время близко к времени одной ноды, а не к сумме по всем.

# Comparison nuances

1. Кодирование строки неоднозначно, и разные данные могут дать одинаковый хеш, то есть diff пропустит расхождение:

COALESCE(x::text, '') склеивает NULL и пустую строку: строки (NULL, 'a') и ('', 'a') неразличимы;
разделитель | не экранируется: ('a|b', 'c') и ('a', 'b|c') дают один и тот же текст. То же происходит на стыке строк в string_agg.

2. Текст зависит от настроек сессии. timestamptz, date, interval, bytea, float выводятся по TimeZone, DateStyle, IntervalStyle, bytea_output, extra_float_digits. ACE фиксирует их при сравнении схем (collect.go:496), но не в соединениях для хеширования (auth.go:241). Если у нод разный TimeZone по умолчанию, все блоки с timestamptz будут считаться разными. Это ложные расхождения, а не пропущенные, но тоже плохо.

## Problem

The data is not the cause. ACE builds the block ranges incorrectly for large tables:

1. For tables with more than 100M rows, `computeSamplingParameters` selects `TABLESAMPLE SYSTEM(0.01)`. On this table that gives about 380K sampled keys.
2. `numBlocks = rows / block_size ≈ 3.79M`. `ntile(3.79M)` over 380K rows puts one row in each bucket. So the build makes about 380K blocks of about 10K rows on average, not 1000.
3. `SYSTEM` sampling takes whole heap pages (about 30 rows each). When the PK order follows the physical order, this gives about 30 very small blocks per sampled page, then one large gap before the next sampled page. Gaps are about 300K rows on average, and the largest gaps reach several million rows. A block of 2–3M rows gives more than 1 GB of row text.

For tables over 100M rows, ACE cannot produce blocks smaller than about 10K rows, and it cannot limit the maximum block size. `table-diff` uses the same range query (`GeneratePkeyOffsetsQuery`, same sample settings) and the same `string_agg` hash (`TDBlockHashSQL`), so it has the same risk.

## Proposed fix

1. **Hash rows first.** The leaf hash should combine fixed-size row hashes, for example `digest(string_agg(digest(row_text, 'sha256'), '' ORDER BY pk), 'sha256')`. This needs 32 bytes per row and makes the hash independent of row width. It changes the hash, so `CurrentHashVersion` must be increased.
2. **Exact block size.** The reference node reads its rows in PK order and starts a new block every M rows (M = `-b`). The block size is then exact and does not depend on a sample.
3. **Histogram only to split the work.** Use `pg_stats.histogram_bounds` to split the key space into up to 10,000 parts. Each part is one unit of work for one worker and one query, and returns boundaries and hashes for many blocks. The histogram can be stale (for example, the last open part after many inserts). This changes only how the work is shared, not the block sizes. If there are no statistics, use a single part.
4. **Same boundaries on all nodes.** Only the reference node computes boundaries. Other nodes hash by the reference list (for a single-column PK, with `width_bucket(pk, boundaries)`). They can run in parallel after the reference node is done. Use the same rule for block split in `mtree update`.
5. **Fault tolerance.** Commit after each part, allow a build to continue after a failure, and stop all workers on the first error (`errgroup` with context cancel).
6. **Same fixes for `table-diff`.** It uses the same range query and the same hash query.

## Acceptance criteria

- A test table with more than 100M rows and PK order equal to physical order: with the current code, block sizes are very uneven. After the fix, no block on the reference node has more than M rows.
- A table with wide rows (large `jsonb`/`bytea`) builds without SQLSTATE 54000.
- If a worker fails, the build stops within seconds, and the parts that were already committed are kept.
- After the build, the leaf ranges are the same on all nodes. After `mtree update` with different data on two nodes, they stay the same.
