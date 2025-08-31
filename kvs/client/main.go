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

func (client *Client) Send_Asynch_Batch(putData []kvs.BatchOperation) *rpc.Call {
	request := kvs.Batch_Request{
		Data: putData,
	}
	response := kvs.Batch_Response{}
	call := client.rpcClient.Go("KVService.Process_Batch", &request, &response, nil)
	if call.Error != nil {
		log.Fatal(call.Error)
	}

	return call
}

func runClient(id int, addr string, done *atomic.Bool, workload *kvs.Workload, resultsCh chan<- uint64, asynch bool) {
	client := Dial(addr)

	value := strings.Repeat("x", 128)
	const batchSize = 1024

	opsCompleted := uint64(0)

	for !done.Load() {
		// Create a batch of operations, consisting of both Gets and Puts
		batchData := make([]kvs.BatchOperation, 0, batchSize)

		for j := 0; j < batchSize; j++ {
			op := workload.Next()
			key := fmt.Sprintf("%d", op.Key)
			if op.IsRead {
				//client.Get(key)
				batchData = append(batchData, kvs.BatchOperation{Key: key, IsRead: true})
			} else {
				//client.Put(key, value)
				batchData = append(batchData, kvs.BatchOperation{Key: key, Value: value, IsRead: false})
			}
			opsCompleted++
		}

		if asynch {
			calls := make([]*rpc.Call, 0, batchSize)
			if len(batchData) > 0 {
				calls = append(calls, client.Send_Asynch_Batch(batchData))
			}

			// Wait for all asynchronous calls to complete.
			// Similar to what we did in HW1.
			// call.Done is a channel which signals when the call was finished
			// Response data is stored in call.Reply (NEEDS SOME TESTING)
			for _, call := range calls {
				<-call.Done
			}
		} else {
			// Send only 1 RPC call size of batchSize
			if len(batchData) > 0 {
				client.Send_Synch_Batch(batchData)
			}
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

	// Change this value to run asynchronously
	asynch := flag.Bool("asynch", true, "Enable asynchronous RPC calls")

	flag.Parse()

	if len(hosts) == 0 {
		hosts = append(hosts, "localhost:8080")
	}

	fmt.Printf(
		"hosts %v\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"Asynch RPC %t\n"+
			"secs %d\n",
		hosts, *theta, *workload, *asynch, *secs,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64)

	host := hosts[0]
	clientId := 0
	go func(clientId int) {
		workload := kvs.NewWorkload(*workload, *theta)
		runClient(clientId, host, &done, workload, resultsCh, *asynch)
	}(clientId)

	time.Sleep(time.Duration(*secs) * time.Second)
	done.Store(true)

	opsCompleted := <-resultsCh

	elapsed := time.Since(start)

	opsPerSec := float64(opsCompleted) / elapsed.Seconds()
	fmt.Printf("throughput %.2f ops/s\n", opsPerSec)
}
