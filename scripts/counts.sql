-- public schema 每張表的精確筆數（不是 planner 的估計值），一行一張表：table|count。
-- sync-db.sh 在兩邊各跑一次，排序後比對。
select table_name || '|' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by table_name;
