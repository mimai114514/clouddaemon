package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"clouddaemon-agent/internal/config"
)

func TestCheckOrigin(t *testing.T) {
	cfg := config.Config{AllowedOrigins: []string{"https://panel.example.com"}}
	if !checkOrigin(cfg, "https://panel.example.com") {
		t.Fatal("expected origin to be allowed")
	}
	if checkOrigin(cfg, "https://other.example.com") {
		t.Fatal("expected origin to be rejected")
	}
}

func TestAuthorize(t *testing.T) {
	cfg := config.Config{AdminToken: "secret"}
	r := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	r.Header.Set("Authorization", "Bearer secret")
	if !authorize(cfg, r) {
		t.Fatal("expected authorization to pass")
	}
}
