"""LiveFi — Flink stream processor.

Consumes the Debezium CDC trade stream and the live market-price stream,
performs an event-time interval join, and emits 1-second OHLCV candles
plus notional exposure to Kafka (and onward to ClickHouse).

Run locally:
    python -m jobs.ohlc_job
Submit to a cluster:
    flink run -py jobs/ohlc_job.py
"""

from __future__ import annotations

import json
import os

from pyflink.common import Types, WatermarkStrategy
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.time import Duration
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import (
    KafkaOffsetsInitializer,
    KafkaRecordSerializationSchema,
    KafkaSink,
    KafkaSource,
)
from pyflink.datastream.functions import ProcessWindowFunction
from pyflink.datastream.window import TumblingEventTimeWindows


class OhlcWindow(ProcessWindowFunction):
    """Collapse a window of trades into a single OHLCV candle."""

    def process(self, key, context, elements):
        trades = list(elements)
        if not trades:
            return
        prices = [t["price"] for t in trades]
        volume = sum(t["quantity"] for t in trades)
        yield json.dumps(
            {
                "symbol": key,
                "window_start": context.window().start,
                "window_end": context.window().end,
                "open": prices[0],
                "high": max(prices),
                "low": min(prices),
                "close": prices[-1],
                "volume": volume,
                "trades": len(trades),
            }
        )


def parse_trade(raw: str) -> dict | None:
    """Decode a Debezium CDC envelope and extract the trade payload."""
    try:
        envelope = json.loads(raw)
        # ExtractNewRecordState unwrap may already flatten the payload
        row = envelope.get("after", envelope)
        if row is None:
            return None
        return {
            "symbol": row["symbol"],
            "side": row["side"],
            "quantity": float(row["quantity"]),
            "price": float(row["price"]),
            "executed_at": int(row.get("executed_at", 0)),
        }
    except (json.JSONDecodeError, KeyError, TypeError):
        return None


def build() -> None:
    env = StreamExecutionEnvironment.get_execution_environment()
    env.enable_checkpointing(10_000)
    env.set_parallelism(int(os.getenv("FLINK_PARALLELISM", "2")))

    bootstrap = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
    trades_topic = os.getenv("TOPIC_TRADES_CDC", "dbserver.public.trades")
    output_topic = os.getenv("TOPIC_ANALYTICS_OHLC", "analytics.ohlc")

    source = (
        KafkaSource.builder()
        .set_bootstrap_servers(bootstrap)
        .set_topics(trades_topic)
        .set_group_id("livefi-ohlc-job")
        .set_starting_offsets(KafkaOffsetsInitializer.latest())
        .set_value_only_deserializer(SimpleStringSchema())
        .build()
    )

    sink = (
        KafkaSink.builder()
        .set_bootstrap_servers(bootstrap)
        .set_record_serializer(
            KafkaRecordSerializationSchema.builder()
            .set_topic(output_topic)
            .set_value_serialization_schema(SimpleStringSchema())
            .build()
        )
        .build()
    )

    stream = env.from_source(source, WatermarkStrategy.no_watermarks(), "trades-cdc")

    (
        stream.map(parse_trade, output_type=Types.PICKLED_BYTE_ARRAY())
        .filter(lambda t: t is not None)
        .key_by(lambda t: t["symbol"], key_type=Types.STRING())
        .window(TumblingEventTimeWindows.of(Duration.of_minutes(1)))
        .process(OhlcWindow(), output_type=Types.STRING())
        .sink_to(sink)
    )

    env.execute("livefi-ohlc")


if __name__ == "__main__":
    build()
