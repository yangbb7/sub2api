package service

import (
	"strings"

	"github.com/tidwall/gjson"
)

type OpenAIResponsesRequestMeta struct {
	Model              string
	ModelExists        bool
	ModelIsString      bool
	Stream             bool
	StreamExists       bool
	StreamIsBool       bool
	PreviousResponseID string
	PromptCacheKey     string
}

func ExtractOpenAIResponsesRequestMeta(body []byte) (OpenAIResponsesRequestMeta, bool) {
	if !gjson.ValidBytes(body) {
		return OpenAIResponsesRequestMeta{}, false
	}

	values := gjson.GetManyBytes(body, "model", "stream", "previous_response_id", "prompt_cache_key")
	modelResult := values[0]
	streamResult := values[1]

	meta := OpenAIResponsesRequestMeta{
		ModelExists:        modelResult.Exists(),
		ModelIsString:      modelResult.Type == gjson.String,
		StreamExists:       streamResult.Exists(),
		StreamIsBool:       streamResult.Type == gjson.True || streamResult.Type == gjson.False,
		PreviousResponseID: strings.TrimSpace(values[2].String()),
		PromptCacheKey:     strings.TrimSpace(values[3].String()),
	}
	if meta.ModelIsString {
		meta.Model = modelResult.String()
	}
	if meta.StreamIsBool {
		meta.Stream = streamResult.Bool()
	}
	return meta, true
}
