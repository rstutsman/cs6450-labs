package main

import (
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"net/rpc"
	"sync/atomic"
	"time"

	"github.com/rstutsman/cs6450-labs/kvs"
)

type Client struct {
	rpcClients []*rpc.Client
}

func Dial(addrs []string) *Client {
	rpcClients := make([]*rpc.Client, 0)
	for _, addr := range addrs {
		fmt.Printf("Connecting to %v\n", addr)
		rpcClient, err := rpc.DialHTTP("tcp", addr)
		if err != nil {
			log.Fatal(err)
		}
		rpcClients = append(rpcClients, rpcClient)
	}

	return &Client{rpcClients}
}

func HashFNV(s string) uint32 {
	h := fnv.New32a()
	h.Write([]byte(s))
	return h.Sum32()
}

func (client *Client) Get(key string) string {
	request := kvs.GetRequest{
		Key: key,
	}

	i := HashFNV(key) % uint32(len(client.rpcClients))
	cl := client.rpcClients[i]

	response := kvs.GetResponse{}
	err := cl.Call("KVService.Get", &request, &response)
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

	i := HashFNV(key) % uint32(len(client.rpcClients))
	cl := client.rpcClients[i]

	response := kvs.PutResponse{}
	err := cl.Call("KVService.Put", &request, &response)
	if err != nil {
		log.Fatal(err)
	}
}

func runClient(id int, addrs []string, done *atomic.Bool, workload *kvs.Workload, resultsCh chan<- uint64) {
	client := Dial(addrs)

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
	//host := flag.String("host", "localhost", "Host to connect to")
	//port := flag.String("port", "8080", "Port to connect to")
	clients := flag.Int("clients", 3, "Number of concurrent clients")
	theta := flag.Float64("theta", 0.99, "Zipfian distribution skew parameter")
	workload := flag.String("workload", "YCSB-A", "Workload type (YCSB-A, YCSB-B, YCSB-C)")
	secs := flag.Int("secs", 10, "Duration in seconds for each client to run")
	flag.Parse()

	//addrs := make([]string, 0)
	//addrs = append(addrs, "10.10.1.3:8080")
	//addrs = append(addrs, "10.10.1.4:8080")
	addrs := []string{
	"10.10.1.2:8080",
	"10.10.1.3:8080",
	"10.10.1.4:8080"}
	//addrs = append(addrs, fmt.Sprintf("%v:%v", *host, p))
	//addrs = append(addrs, fmt.Sprintf("%v:%v", *host, p + 1))
	fmt.Printf(
		"server %v\n"+
		"server %v\n"+
			"clients %d\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"secs %d\n",
		addrs[0], addrs[1], *clients, *theta, *workload, *secs,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64, *clients)

	for i := 0; i < *clients; i++ {
		go func(i int) {
			workload := kvs.NewWorkload(*workload, *theta)
			runClient(i, addrs, &done, workload, resultsCh)
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
