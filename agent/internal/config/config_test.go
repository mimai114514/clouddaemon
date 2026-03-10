package config

import "testing"

func TestValidate(t *testing.T) {
	cfg := Config{
		ListenAddr:          ":8443",
		TLSCertFile:         "cert.pem",
		TLSKeyFile:          "key.pem",
		AdminToken:          "secret",
		AllowedOrigins:      []string{"https://panel.example.com"},
		LogTailDefaultLines: 200,
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() returned error: %v", err)
	}
}

func TestValidateMissingFields(t *testing.T) {
	cfg := Config{}
	if err := cfg.Validate(); err == nil {
		t.Fatal("Validate() expected an error")
	}
}
