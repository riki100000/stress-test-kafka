package main

import (
	"fmt"
	"log"
	"sync/atomic"
	"time"

	"github.com/IBM/sarama"
)

// 格式化带宽显示
func formatBandwidth(bytesPerSecond float64) string {
	const (
		KB = 1024
		MB = KB * 1024
		GB = MB * 1024
	)

	if bytesPerSecond >= GB {
		return fmt.Sprintf("%.2f GB/s", bytesPerSecond/GB)
	} else if bytesPerSecond >= MB {
		return fmt.Sprintf("%.2f MB/s", bytesPerSecond/MB)
	} else if bytesPerSecond >= KB {
		return fmt.Sprintf("%.2f KB/s", bytesPerSecond/KB)
	}
	return fmt.Sprintf("%.0f B/s", bytesPerSecond)
}

const (
	// Kafka broker 地址
	broker = "localhost:19092"
	topic  = "stress-test-topic"

	// 测试参数 - 1 亿条消息（3 分钟完成）
	numGoroutines = 100000                        // 并发 goroutine 数量（高并发）
	msgsPerWorker = 100_0000                      // 每个 goroutine 发送 10 万条消息
	totalMessages = numGoroutines * msgsPerWorker // 1 亿条消息
)

func main() {
	fmt.Println("🚀 Kafka 100 Million Messages Stress Test (3min Target)")
	fmt.Printf("Configuration:\n")
	fmt.Printf("  - Broker: %s\n", broker)
	fmt.Printf("  - Topic: %s\n", topic)
	fmt.Printf("  - Goroutines: %d\n", numGoroutines)
	fmt.Printf("  - Messages per goroutine: %d\n", msgsPerWorker)
	fmt.Printf("  - Total messages: %d (%.2f million)\n", totalMessages, float64(totalMessages)/1e6)
	fmt.Printf("  - Target: Complete in 3 minutes\n")
	fmt.Println()

	// 配置 Kafka producer - 使用异步 producer 提高性能
	config := sarama.NewConfig()
	config.Producer.Return.Successes = false // 关闭 success channel 提高性能
	config.Producer.Return.Errors = true
	config.Producer.Retry.Max = 5
	config.Producer.RequiredAcks = 1 // 使用 1 提高吞吐量（leader 确认即可）
	config.Producer.Compression = sarama.CompressionSnappy

	// 批量发送配置 - 超高吞吐量优化
	config.Producer.Flush.Messages = 10000                   // 每批 10000 条（最大批处理）
	config.Producer.Flush.Frequency = 100 * time.Millisecond // 每 100ms 刷新一次
	config.Producer.MaxMessageBytes = 10000000               // 10MB（增大缓冲区）

	// 创建 producer
	producer, err := sarama.NewAsyncProducer([]string{broker}, config)
	if err != nil {
		log.Fatalf("❌ Failed to create producer: %v", err)
	}
	defer producer.Close()

	fmt.Println("✅ Async Producer created successfully")
	fmt.Println("📊 Starting to send messages...")

	var successCount int64
	var errorCount int64
	var totalBytesSent int64 // 总发送字节数
	startTime := time.Now()
	lastReportTime := startTime

	// 错误处理 goroutine
	go func() {
		for err := range producer.Errors() {
			atomic.AddInt64(&errorCount, 1)
			if atomic.LoadInt64(&errorCount) <= 5 { // 只打印前 5 个错误
				fmt.Printf("❌ Error: %v\n", err)
			}
		}
	}()

	// 启动多个 goroutine 并发发送消息
	for i := 0; i < numGoroutines; i++ {
		go func(workerID int) {
			for j := 0; j < msgsPerWorker; j++ {
				message := fmt.Sprintf("Worker-%d-Message-%d-Timestamp-%d",
					workerID, j, time.Now().UnixNano())

				msg := &sarama.ProducerMessage{
					Topic: topic,
					Key:   sarama.StringEncoder(fmt.Sprintf("key-%d-%d", workerID, j)),
					Value: sarama.StringEncoder(message),
					Headers: []sarama.RecordHeader{
						{
							Key:   []byte("worker-id"),
							Value: []byte(fmt.Sprintf("%d", workerID)),
						},
					},
				}

				// 异步发送消息
				producer.Input() <- msg
				atomic.AddInt64(&successCount, 1)
				// 统计发送的字节数（估算）
				estimatedBytes := int64(len(message) + len(msg.Key.(sarama.StringEncoder)) + 50) // 包括key、headers等
				atomic.AddInt64(&totalBytesSent, estimatedBytes)

				// 每 100 万条消息报告一次进度
				total := atomic.LoadInt64(&successCount) + atomic.LoadInt64(&errorCount)
				if total%1_000_000 == 0 {
					now := time.Now()
					elapsed := now.Sub(startTime)
					duration := now.Sub(lastReportTime)
					rate := float64(1_000_000) / duration.Seconds()
					totalBytes := atomic.LoadInt64(&totalBytesSent)
					bandwidth := float64(totalBytes) / elapsed.Seconds()

					// 格式化为合适的单位
					bandwidthStr := formatBandwidth(bandwidth)

					fmt.Printf("📊 Progress: %d/%d (%.2f%%) | Rate: %.0f msg/s | Bandwidth: %s | Elapsed: %v\n",
						total, totalMessages, float64(total)/float64(totalMessages)*100, rate, bandwidthStr, elapsed)
					lastReportTime = now
				}
			}
		}(i)
	}

	// 等待所有消息发送完成
	expectedTotal := int64(totalMessages)
	for atomic.LoadInt64(&successCount)+atomic.LoadInt64(&errorCount) < expectedTotal {
		time.Sleep(100 * time.Millisecond)
	}

	duration := time.Since(startTime)

	// 输出统计信息
	fmt.Println()
	fmt.Println("============================================================")
	fmt.Println("📊 Stress Test Results")
	fmt.Println("============================================================")
	fmt.Printf("Total messages sent: %d\n", atomic.LoadInt64(&successCount)+atomic.LoadInt64(&errorCount))
	fmt.Printf("Success: %d\n", atomic.LoadInt64(&successCount))
	fmt.Printf("Errors: %d\n", atomic.LoadInt64(&errorCount))
	fmt.Printf("Success rate: %.2f%%\n",
		float64(atomic.LoadInt64(&successCount))/float64(totalMessages)*100)
	fmt.Printf("Duration: %v\n", duration)
	fmt.Printf("Throughput: %.0f messages/second\n",
		float64(atomic.LoadInt64(&successCount))/duration.Seconds())

	// 带宽统计
	totalBytes := atomic.LoadInt64(&totalBytesSent)
	averageBandwidth := float64(totalBytes) / duration.Seconds()
	fmt.Printf("Average bandwidth: %s\n", formatBandwidth(averageBandwidth))
	fmt.Printf("Total data sent: %.2f MB\n", float64(totalBytes)/1024/1024)

	fmt.Printf("Average latency: %.2f ms/message\n",
		duration.Seconds()*1000/float64(atomic.LoadInt64(&successCount)))
	fmt.Println("============================================================")

	if atomic.LoadInt64(&errorCount) > 0 {
		fmt.Println("⚠️  Some messages failed to send")
	} else {
		fmt.Println("🎉 All messages sent successfully!")
	}
}
