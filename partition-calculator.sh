#!/bin/bash

# Kafka 分区数计算器 - 大规模生产环境决策助手

cat << 'HEADER'

╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║           Kafka 分区数计算器 v1.0 - 生产环境配置助手                       ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

HEADER

read -p "请输入日均数据量（GB，例如：1000）: " daily_gb
read -p "请输入预期最大消费者数（例如：100）: " max_consumers
read -p "请输入可用的 Broker 数量（例如：20）: " broker_count
read -p "请输入副本因子（通常 2 或 3）: " replication_factor

# 计算
single_partition_throughput=100  # MB/s, 保守估计
single_partition_capacity=100     # GB, 单分区日均容量

# 四个维度的需求
throughput_partitions=$(echo "scale=0; ($daily_gb * 1024) / ($single_partition_throughput * 86.4)" | bc)
consumer_partitions=$max_consumers
fault_tolerance_partitions=$((broker_count * 3))
capacity_partitions=$(echo "scale=0; $daily_gb / $single_partition_capacity" | bc)

# 取最大值
recommended_partitions=$(echo "$throughput_partitions $consumer_partitions $fault_tolerance_partitions $capacity_partitions" | tr ' ' '\n' | sort -rn | head -1)

# 上限检查
if [ "$recommended_partitions" -gt 2000 ]; then
    recommended_partitions=2000
    warning="⚠️ 超过 2000 分区，建议分多主题或多集群！"
fi

cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 计算结果
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

输入参数：
  ├─ 日均数据量: ${daily_gb} GB
  ├─ 最大消费者数: ${max_consumers}
  ├─ Broker 数量: ${broker_count}
  └─ 副本因子: ${replication_factor}

计算维度：
  ├─ 吞吐量需求: ${throughput_partitions} 分区 (${throughput_partitions} × 100MB/s)
  ├─ 消费者并行: ${consumer_partitions} 分区 (每消费者 1 分区)
  ├─ 容错扩展: ${fault_tolerance_partitions} 分区 (broker × 3)
  └─ 存储均衡: ${capacity_partitions} 分区 (100GB/分区)

✅ 推荐分区数: ${recommended_partitions} 分区
${warning}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 docker-compose.yml 配置建议
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

在每个 broker 的 environment 中添加：

  KAFKA_NUM_PARTITIONS: ${recommended_partitions}
  KAFKA_DEFAULT_REPLICATION_FACTOR: ${replication_factor}
  KAFKA_MIN_INSYNC_REPLICAS: $((replication_factor - 1))

创建 topic 时使用：

  docker exec kafka-controller-1 /opt/kafka/bin/kafka-topics.sh \\
    --create \\
    --bootstrap-server kafka-controller-1:9092 \\
    --topic your-topic-name \\
    --partitions ${recommended_partitions} \\
    --replication-factor ${replication_factor} \\
    --config min.insync.replicas=$((replication_factor - 1))

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📈 性能预期
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  吞吐量: $(echo "scale=1; $recommended_partitions * 100" | bc) MB/s 理论值
  并发消费者: 最多 ${recommended_partitions} 个无冲突分配
  存储成本: ${replication_factor}x（每条消息存储 ${replication_factor} 份）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

