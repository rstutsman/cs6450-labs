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

// Sends a batch of RPC calls synchronously
func (client *Client) Send_Synch_Batch(putData []kvs.BatchOperation) []string {
	request := kvs.Batch_Request{
		Data: putData,
	}
	response := kvs.Batch_Response{}
	err := client.rpcClient.Call("KVService.Process_Batch", &request, &response)
	if err != nil {
		log.Fatal(err)
	}

	return response.Values
}

// Sends a batch of RPC calls asynchronously
// The difference is in rpcClient.Call vs rpcClient.Go
// .Go returns  a Call datastructure with a "Done" channel in it, which needs to be waited on
// (see homework 1, as it is very similar)
func (client *Client) Send_Asynch_Batch(putData []kvs.BatchOperation) *rpc.Call {
	request := kvs.Batch_Request{
		Data: putData,
	}
	response := kvs.Batch_Response{}

	call := client.rpcClient.Go("KVService.Process_Batch", &request, &response, nil)

	return call
}

func hashKey(key string) uint32 {
	h := fnv.New32a()
	h.Write([]byte(key))
	return h.Sum32()
}

func runConnection(wg *sync.WaitGroup, hosts []string, done *atomic.Bool, workload *kvs.Workload, totalOpsCompleted *uint64, asynch bool) {
	defer wg.Done()

	// Dial all hosts
	clients := make([]*Client, len(hosts))
	for i, host := range hosts {
		clients[i] = Dial(host)
	}

	value := strings.Repeat("x", 128)
	const batchSize = 5000 //1024
	clientOpsCompleted := uint64(0)

	for !done.Load() {
		// Create batches for each server
		requests := make([][]kvs.BatchOperation, len(hosts))

		// organize work from workload
		for j := 0; j < batchSize; j++ {
			// XXX: something may go awry here when the total number of "yields"
			// from workload.Next() is not a clean multiple of batchSize.
			op := workload.Next()
			key := fmt.Sprintf("%d", op.Key)

			// Hash key to determine which server
			serverIndex := int(hashKey(key)) % len(hosts)
			batchRequestData := requests[serverIndex]
			var batchOp kvs.BatchOperation

			if op.IsRead {
				batchOp.Key = key
				batchOp.Value = ""
				batchOp.IsRead = true
			} else {
				batchOp.Key = key
				batchOp.Value = value
				batchOp.IsRead = false
			}
			batchRequestData = append(batchRequestData, batchOp)
			requests[serverIndex] = batchRequestData
			clientOpsCompleted++
		}

		// Send batches to each server
		for i := 0; i < len(hosts); i++ {
			batchRequestData := requests[i]
			if len(batchRequestData) > 0 {
				if asynch {
					clients[i].Send_Asynch_Batch(batchRequestData)
				} else {
					clients[i].Send_Synch_Batch(batchRequestData)
				}
			}
		}
	}
	atomic.AddUint64(totalOpsCompleted, clientOpsCompleted) // TODO: only really accurate after at-least-once
}

func runClient(id int, hosts []string, done *atomic.Bool, workload *kvs.Workload, numConnections int, resultsCh chan<- uint64, asynch bool) {
	var wg sync.WaitGroup
	totalOpsCompleted := uint64(0)

	// instantiate waitgroup before goroutines
	for connId := 0; connId < numConnections; connId++ {
		wg.Add(1)
	}
	for connId := 0; connId < numConnections; connId++ {
		go runConnection(&wg, hosts, done, workload, &totalOpsCompleted, asynch)
	}

	fmt.Println("waiting for connections to finish")
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

	// Change this value to run asynchronously
	asynch := flag.Bool("asynch", false, "Enable asynchronous RPC calls")

	flag.Parse()

	if len(hosts) == 0 {
		hosts = append(hosts, "localhost:8080")
	}

	fmt.Printf(
		"hosts %v\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"secs %d\n"+
			"connections %d\n"+
			"Asynch RPC %t\n",
		hosts, *theta, *workload, *secs, *numConnections, *asynch,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64)

	clientId := 0
	go func(clientId int) {
		workload := kvs.NewWorkload(*workload, *theta)
		runClient(clientId, hosts, &done, workload, *numConnections, resultsCh, *asynch)
	}(clientId)

	time.Sleep(time.Duration(*secs) * time.Second)
	done.Store(true)

	opsCompleted := <-resultsCh

	elapsed := time.Since(start)

	opsPerSec := float64(opsCompleted) / elapsed.Seconds()
	fmt.Printf("throughput %.2f ops/s\n", opsPerSec)
}
