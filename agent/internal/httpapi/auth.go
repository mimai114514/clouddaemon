package httpapi

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"clouddaemon-agent/internal/config"
)

func checkOrigin(cfg config.Config, origin string) bool {
	if origin == "" {
		return true
	}
	for _, allowed := range cfg.AllowedOrigins {
		if allowed == "*" || allowed == origin {
			return true
		}
	}
	return false
}

func authorize(cfg config.Config, r *http.Request) bool {
	token := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(cfg.AdminToken)) == 1
}

func corsHeaders(w http.ResponseWriter, r *http.Request, cfg config.Config) bool {
	origin := r.Header.Get("Origin")
	if !checkOrigin(cfg, origin) {
		writeError(w, http.StatusForbidden, "forbidden_origin", "Origin is not allowed.")
		return false
	}
	if origin != "" {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Vary", "Origin")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	}
	return true
}
