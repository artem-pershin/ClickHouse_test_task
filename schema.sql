create table wbdailydata_shard on cluster '{cluster}'
(
    date  DateTime,
    sku   UInt32,
    name  String,
    sells Decimal64(4)
) Engine = ReplicatedMergeTree('/clickhouse/tables/{database}/{table}/{shard}', '{replica}')
partition by toYYYYMMDD(date)
primary key name
order by (name)
settings index_granularity = 8192;

create table wbdailydata on cluster '{cluster}'
as wbdailydata_shard
ENGINE = Distributed('{cluster}', 'default', 'wbdailydata_shard', sku);

create table wbdailydata_sells_agg_shard on cluster '{cluster}'
(
   name String,
   date Date,
   sells Decimal64(4)
)
ENGINE = ReplicatedSummingMergeTree('/clickhouse/tables/{database}/{table}/{shard}', '{replica}')
primary key (name)
PARTITION BY toYYYYMM(date)
order by (name, date);

create table wbdailydata_sells_agg on cluster '{cluster}'
as wbdailydata_sells_agg_shard
ENGINE = Distributed('{cluster}', 'default', 'wbdailydata_sells_agg_shard', rand());

create materialized view wbdailydata_sells_agg_mv on cluster '{cluster}' to dailydata_sells_agg_shard
as
select
name,
toDate(date) as date,
sum(sells) as sells
from wbdailydata_shard
group by name, date;

create table similar_goods_edges on cluster '{cluster_all_replicas}'
(
    good_name String,
    similar_goods Array(String),
    date Date
) Engine = ReplicatedMergeTree('/clickhouse/tables/{database}/{table}', '{cluster_all_replica}')
partition by date
order by tuple()
TTL date + INTERVAL 30 day
settings ttl_only_drop_parts = 1;

create table similar_goods on cluster '{cluster_all_replicas}'
(
    similar_goods Array(String)
) Engine = ReplicatedMergeTree('/clickhouse/tables/{database}/{table}', '{cluster_all_replica}')
order by tuple();

insert into similar_goods_edges values
('A', ['B', 'C', 'D'], now()),
('B', ['AA', 'CC', 'DD'], now());

insert into wbdailydata values
(now(), 1, 'A', 1.0),
(now(), 2, 'B', 2.0),
(now(), 3, 'C', 3.0),
(now(), 4, 'D', 4.0),
(now(), 5, 'AA', 5.0),
(now(), 6, 'BB', 6.0),
(now(), 7, 'CC', 7.0),
(now(), 8, 'DD', 8.0);

insert into similar_goods
values (['A', 'B', 'C', 'D', 'AA', 'CC', 'DD']), (['BB']);

select
    name,
    sum(sells)
from wbdailydata_sells_agg
where name in (select arrayJoin(similar_goods) from similar_goods where has(similar_goods, 'A'))
and (date >= now() - interval 30 day)
group by name
order by name;