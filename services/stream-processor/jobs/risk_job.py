"""LiveFi — streaming risk computation job.

Consumes trade events, maintains per-portfolio state, and emits
simplified risk snapshots (notional exposure, rolling volatility proxy).

Run:
    flink run -py jobs/risk_job.py
"""

from __future__ import annotations

import json
import os

from pyflink.common import Types
from pyflink.common.serialization import SimpleStringSchema
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import (
    KafkaOffsetsInitializer,
    KafkaRecordSerializationSchema,
    KafkaSink,
    KafkaSource,
)


def build() -> None:
    env = StreamExecutionEnvironment.get_execution_environment()
    env.enable_checkpointing(10_000)
    env.set_parallelism(int(os.getenv("FLINK_PARALLELISM", "2")))

    bootstrap = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")

    source = (
        KafkaSource.builder()
        .set_bootstrap_servers(bootstrap)
        .set_topics(os.getenv("TOPIC_TRADES_CDC", "dbserver.public.trades"))
        .set_group_id("livefi-risk-job")
        .set_starting_offsets(KafkaOffsetsInitializer.latest())
        .set_value_only_deserializer(SimpleStringSchema())
        .build()
    )

    sink = (
        KafkaSink.builder()
        .set_bootstrap_servers(bootstrap)
        .set_record_serializer(
            KafkaRecordSerializationSchema.builder()
            .set_topic(os.getenv("TOPIC_ANALYTICS_RISK", "analytics.risk"))
            .set_value_serialization_schema(SimpleStringSchema())
            .build()
        )
        .build()
    )

    stream = env.from_source(source, None, "trades-cdc")

    # NOTE: replace with a KeyedProcessFunction carrying ValueState for
    # real per-portfolio exposure and volatility accumulation.
    def to_exposure(raw: str) -> str | None:
        try:
            row = json.loads(raw)
            row = row.get("after", row)
            notional = float(row["quantity"]) * float(row["price"])
            return json.dumps(
                {
                    "portfolio_id": row.get("portfolio_id", "default"),
                    "symbol": row["symbol"],
                    "notional": notional,
                }
            )
        except (json.JSONDecodeError, KeyError, TypeError):
            return None

    stream.map(to_exposure, output_type=Types.STRING()).filter(
        lambda x: x is not None
    ).sink_to(sink)

    env.execute("livefi-risk")


if __name__ == "__main__":
    build()
