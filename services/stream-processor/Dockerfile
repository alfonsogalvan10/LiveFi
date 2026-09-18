FROM flink:1.19-scala_2.12-java17

USER root

# PyFlink runtime deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip python3-dev \
 && ln -sf /usr/bin/python3 /usr/bin/python \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /opt/flink/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /opt/flink/requirements.txt

# Kafka connector JARs (Flink 1.19 bundled connector)
RUN curl -fsSL -o /opt/flink/lib/flink-sql-connector-kafka-3.1.0-1.19.jar \
    https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.1.0-1.19/flink-sql-connector-kafka-3.1.0-1.19.jar

COPY jobs /opt/flink/usrlib

USER flink
WORKDIR /opt/flink
