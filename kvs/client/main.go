package main

import (
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"net/rpc"
	"strings"
	"sync"
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

func hashKey(key string) uint32 {
	h := fnv.New32a()
	h.Write([]byte(key))
	return h.Sum32()
}

func runClient(id int, hosts []string, done *atomic.Bool, workload *kvs.Workload, numConnections int, resultsCh chan<- uint64) {
	var wg sync.WaitGroup
	totalOpsCompleted := uint64(0)

	for connId := 0; connId < numConnections; connId++ {
		wg.Add(1)
		go func(connectionId int) {
			defer wg.Done()

			// Dial all hosts
			clients := make([]*Client, len(hosts))
			for i, host := range hosts {
				clients[i] = Dial(host)
			}

			value := strings.Repeat("x", 128)
			const batchSize = 1024
			opsCompleted := uint64(0)

			for !done.Load() {
				// Create batches for each server
				getKeys := make([][]string, len(hosts)) // nil slices are fine for append
				putData := make([]map[string]string, len(hosts))

				// Only initialize putData maps (getKeys slices don't need it)
				for i := range putData {
					putData[i] = make(map[string]string)
				}

				for j := 0; j < batchSize; j++ {
					op := workload.Next()
					key := fmt.Sprintf("%d", op.Key)

					// Hash key to determine which server
					serverIndex := int(hashKey(key)) % len(hosts)

					if op.IsRead {
						getKeys[serverIndex] = append(getKeys[serverIndex], key)
					} else {
						putData[serverIndex][key] = value
					}
					opsCompleted++
				}

				// Send batches to each server
				for i := 0; i < len(hosts); i++ {
					if len(getKeys[i]) > 0 {
						clients[i].BatchGet(getKeys[i])
					}
					if len(putData[i]) > 0 {
						clients[i].BatchPut(putData[i])
					}
				}
			}

			atomic.AddUint64(&totalOpsCompleted, opsCompleted)
		}(connId)
	}

	wg.Wait()
	fmt.Printf("Client %d finished operations.\n", id)
	resultsCh <- totalOpsCompleted
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
	numConnections := flag.Int("connections", 1, "Number of connections per client")
	flag.Parse()

	if len(hosts) == 0 {
		hosts = append(hosts, "localhost:8080")
	}

	fmt.Printf(
		"hosts %v\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"secs %d\n"+
			"connections %d\n",
		hosts, *theta, *workload, *secs, *numConnections,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64)

	clientId := 0
	go func(clientId int) {
		workload := kvs.NewWorkload(*workload, *theta)
		runClient(clientId, hosts, &done, workload, *numConnections, resultsCh)
	}(clientId)

	time.Sleep(time.Duration(*secs) * time.Second)
	done.Store(true)

	opsCompleted := <-resultsCh

	elapsed := time.Since(start)

	opsPerSec := float64(opsCompleted) / elapsed.Seconds()
	fmt.Printf("throughput %.2f ops/s\n", opsPerSec)
}
