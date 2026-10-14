package harnessfloat

import "github.com/pelletier/go-toml/v2"

type floats struct {
	A  float64
	B  float32
	C  []float64
	D  map[string]float64
	E  map[string]float32
	In struct {
		F float64
	}
}

// Fuzz decodes the document into float-typed destinations, which routes TOML
// integers through the float parser.
func Fuzz(data []byte) int {
	if len(data) >= 2048 {
		return 0
	}

	ok := 0

	var s floats
	if toml.Unmarshal(data, &s) == nil {
		ok = 1
	}

	var m map[string]float64
	if toml.Unmarshal(data, &m) == nil {
		ok = 1
	}

	var a map[string]interface{}
	if toml.Unmarshal(data, &a) == nil {
		ok = 1
	}

	return ok
}
