package kvs

type Batch_Request struct {
	Data []BatchOperation
}

type Batch_Response struct {
	Values []string
}

type BatchOperation struct {
	Key    string
	Value  string
	IsRead bool
}
