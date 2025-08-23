package main

import (
	"flag"
	"fmt"
	"log"
	"net/rpc"
	"strings"
	"sync/atomic"
	"time"

	"github.com/rstutsman/cs6450-labs/kvs"
)

type Client struct {
	rpcClient *rpc.Client
}

func Dial(addr string) *Client {
	rpcClient, err := rpc.DialHTTP("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}

	return &Client{rpcClient}
}

// Send a batch of keys to retrieve
func (client *Client) BatchGet(keys []string) []string {
	request := kvs.BatchGetRequest{
		Keys: keys,
	}
	response := kvs.BatchGetResponse{}
	err := client.rpcClient.Call("KVService.BatchGet", &request, &response)
	if err != nil {
		log.Fatal(err)
	}

	return response.Values
}

// Send a batch of key-value pairs to modify
func (client *Client) BatchPut(putData map[string]string) {
	request := kvs.BatchPutRequest{
		Data: putData,
	}
	//response := kvs.BatchPutResponse{}
	err := client.rpcClient.Call("KVService.BatchPut", &request, nil)
	if err != nil {
		log.Fatal(err)
	}
}

func runClient(id int, addr string, done *atomic.Bool, workload *kvs.Workload, resultsCh chan<- uint64) {
	client := Dial(addr)

	value := strings.Repeat("x", 128)
	const batchSize = 1024

	opsCompleted := uint64(0)

	for !done.Load() {
		// Create two batches of operations for reads and writes
		var getKeys []string
		putData := make(map[string]string)

		for j := 0; j < batchSize; j++ {
			op := workload.Next()
			key := fmt.Sprintf("%d", op.Key)
			if op.IsRead {
				//client.Get(key)
				getKeys = append(getKeys, key)
			} else {
				//client.Put(key, value)
				putData[key] = value
			}
			opsCompleted++
		}

		// Send only 2 RPC calls.
		if len(getKeys) > 0 {
			client.BatchGet(getKeys)
		}
		if len(putData) > 0 {
			client.BatchPut(putData)
		}
	}

	fmt.Printf("Client %d finished operations.\n", id)

	resultsCh <- opsCompleted
}

type HostList []string

func (h *HostList) String() string {
	return strings.Join(*h, ",")
}

func (h *HostList) Set(value string) error {
	*h = strings.Split(value, ",")
	return nil
}

func main() {
	hosts := HostList{}

	flag.Var(&hosts, "hosts", "Comma-separated list of host:ports to connect to")
	theta := flag.Float64("theta", 0.99, "Zipfian distribution skew parameter")
	workload := flag.String("workload", "YCSB-B", "Workload type (YCSB-A, YCSB-B, YCSB-C)")
	secs := flag.Int("secs", 30, "Duration in seconds for each client to run")
	flag.Parse()

	if len(hosts) == 0 {
		hosts = append(hosts, "localhost:8080")
	}

	fmt.Printf(
		"hosts %v\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"secs %d\n",
		hosts, *theta, *workload, *secs,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64)

	host := hosts[0]
	clientId := 0
	go func(clientId int) {
		workload := kvs.NewWorkload(*workload, *theta)
		runClient(clientId, host, &done, workload, resultsCh)
	}(clientId)

	time.Sleep(time.Duration(*secs) * time.Second)
	done.Store(true)

	opsCompleted := <-resultsCh

	elapsed := time.Since(start)

	opsPerSec := float64(opsCompleted) / elapsed.Seconds()
	fmt.Printf("throughput %.2f ops/s\n", opsPerSec)
}
