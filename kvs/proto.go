package kvs

type Batch_Request struct {
	Data map[string]string
}

type Batch_Response struct {
	Values []string
}