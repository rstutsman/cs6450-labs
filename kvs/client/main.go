package main

import (
	"flag"
	"fmt"
	"log"
	"net/rpc"
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

func (client *Client) Get(key string) string {
	request := kvs.GetRequest{
		Key: key,
	}
	response := kvs.GetResponse{}
	err := client.rpcClient.Call("KVService.Get", &request, &response)
	if err != nil {
		log.Fatal(err)
	}

	return response.Value
}

func (client *Client) Put(key string, value string) {
	request := kvs.PutRequest{
		Key:   key,
		Value: value,
	}
	response := kvs.PutResponse{}
	err := client.rpcClient.Call("KVService.Put", &request, &response)
	if err != nil {
		log.Fatal(err)
	}
}

func runClient(id int, addr string, done *atomic.Bool, workload *kvs.Workload, resultsCh chan<- uint64) {
	client := Dial(addr)

	// XXXXXXXXXXXXXX make correct len value
	const batchSize = 1024

	opsCompleted := uint64(0)

	for !done.Load() {
		for j := 0; j < batchSize; j++ {
			op := workload.Next()
			key := fmt.Sprintf("%d", op.Key)
			if op.IsRead {
				client.Get(key)
			} else {
				// XXXXXXXXXXXX
				client.Put(key, key)
			}
			opsCompleted++
		}
	}

	fmt.Printf("Client %d finished operations.\n", id)

	resultsCh <- opsCompleted
}

func main() {
	host := flag.String("host", "localhost", "Host to connect to")
	port := flag.String("port", "8080", "Port to connect to")
	clients := flag.Int("clients", 3, "Number of concurrent clients")
	theta := flag.Float64("theta", 0.99, "Zipfian distribution skew parameter")
	workload := flag.String("workload", "YCSB-A", "Workload type (YCSB-A, YCSB-B, YCSB-C)")
	secs := flag.Int("secs", 10, "Duration in seconds for each client to run")
	flag.Parse()

	addr := fmt.Sprintf("%v:%v", *host, *port)
	fmt.Printf(
		"server %v\n"+
			"clients %d\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"secs %d\n",
		addr, *clients, *theta, *workload, *secs,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64, *clients)

	for i := 0; i < *clients; i++ {
		go func(i int) {
			workload := kvs.NewWorkload(*workload, *theta)
			runClient(i, addr, &done, workload, resultsCh)
		}(i)
	}

	time.Sleep(time.Duration(*secs) * time.Second)
	done.Store(true)

	opCompleted := uint64(0)
	for i := 0; i < *clients; i++ {
		opCompleted += <-resultsCh
	}

	elapsed := time.Since(start)

	opsPerSec := float64(opCompleted) / elapsed.Seconds()
	fmt.Printf("throughput %.2f ops/s\n", opsPerSec)
}
