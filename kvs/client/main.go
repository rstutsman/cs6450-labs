package main

import (
	"flag"
	"fmt"
	"hash/fnv"
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

type HostList []string

func (h *HostList) Set(value string) error {
	*h = append(*h, value)
	return nil
}

func (h *HostList) String() string {
	return fmt.Sprintf("%v", *h)
}

func hash(s string) int {
	h := fnv.New32a()
	h.Write([]byte(s))
	return int(h.Sum32())
}

func runClient(id int, hosts HostList, done *atomic.Bool, workload *kvs.Workload, resultsCh chan<- uint64) {
	clients := make([]*Client, len(hosts))
	for i, host := range hosts {
		clients[i] = Dial(host)
	}

	value := strings.Repeat("x", 128)
	const batchSize = 1024

	opsCompleted := uint64(0)

	for !done.Load() {
		for j := 0; j < batchSize; j++ {
			op := workload.Next()
			key := fmt.Sprintf("%d", op.Key)
			h := hash(key) % len(clients)
			if op.IsRead {
				clients[h].Get(key)
			} else {
				clients[h].Put(key, value)
			}
			opsCompleted++
		}
	}

	fmt.Printf("Client %d finished operations.\n", id)

	resultsCh <- opsCompleted
}

func main() {
	hosts := HostList{}
	flag.Var(&hosts, "host", "Host to connect to")
	port := flag.String("port", "8080", "Port to connect to")
	theta := flag.Float64("theta", 0.99, "Zipfian distribution skew parameter")
	workload := flag.String("workload", "YCSB-A", "Workload type (YCSB-A, YCSB-B, YCSB-C)")
	secs := flag.Int("secs", 30, "Duration in seconds for each client to run")
	flag.Parse()

	if len(hosts) == 0 {
		hosts = append(hosts, "localhost:8080")
	}

	addr := fmt.Sprintf("%v:%v", hosts.String(), *port)
	fmt.Printf(
		"server %v\n"+
			"theta %.2f\n"+
			"workload %s\n"+
			"secs %d\n",
		addr, *theta, *workload, *secs,
	)

	start := time.Now()

	done := atomic.Bool{}
	resultsCh := make(chan uint64)

	for clientId := 0; clientId < 8; clientId++ {
		go func(clientId int) {
			workload := kvs.NewWorkload(*workload, *theta)
			runClient(clientId, hosts, &done, workload, resultsCh)
		}(clientId)
	}

	time.Sleep(time.Duration(*secs) * time.Second)
	done.Store(true)

	opsCompleted := <-resultsCh

	elapsed := time.Since(start)

	opsPerSec := float64(opsCompleted) / elapsed.Seconds()
	fmt.Printf("throughput %.2f ops/s\n", opsPerSec)
}
