package kvs

type Batch_Request struct {
	Data map[string]string
}

type Batch_Response struct {
	Values []string
}

type BatchPutRequest struct {
	Data map[string]string
}



type BatchPutResponse struct {
}

type BatchGetRequest struct {
	Keys []string
}

type BatchGetResponse struct {
	Keys   []string
	Values []string
}
