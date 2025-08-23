package kvs

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
