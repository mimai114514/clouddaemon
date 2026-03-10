package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"clouddaemon-agent/internal/config"
	"clouddaemon-agent/internal/systemd"
	"github.com/gorilla/websocket"
)

type manager interface {
	SystemdAvailable(ctx context.Context) bool
	ListServices(ctx context.Context, query string) ([]systemd.Service, error)
	GetService(ctx context.Context, serviceName string) (systemd.Service, error)
	Action(ctx context.Context, serviceName, action string) (systemd.Service, error)
	RecentLogs(ctx context.Context, serviceName string, lines int) ([]systemd.LogEntry, error)
	FollowLogs(ctx context.Context, serviceName string) (<-chan systemd.LogEntry, <-chan error, func() error, error)
}

type Options struct {
	Version string
	Config  config.Config
	Manager manager
	Logger  *log.Logger
}

type Server struct {
	version  string
	config   config.Config
	manager  manager
	logger   *log.Logger
	upgrader websocket.Upgrader
}

func NewServer(options Options) (*Server, error) {
	if options.Manager == nil {
		return nil, errors.New("manager is required")
	}
	logger := options.Logger
	if logger == nil {
		logger = log.New(os.Stdout, "", log.LstdFlags)
	}

	server := &Server{
		version: options.Version,
		config:  options.Config,
		manager: options.Manager,
		logger:  logger,
	}
	server.upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return checkOrigin(server.config, r.Header.Get("Origin"))
		},
	}
	return server, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/ping", s.handlePing)
	mux.HandleFunc("/api/v1/services", s.handleServices)
	mux.HandleFunc("/api/v1/services/", s.handleServiceResource)
	mux.HandleFunc("/api/v1/ws/logs", s.handleLogStream)
	return s.loggingMiddleware(mux)
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	if !s.preflight(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Only GET is supported.")
		return
	}
	if !authorize(s.config, r) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Missing or invalid token.")
		return
	}

	hostname, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]any{
		"version":           s.version,
		"hostname":          hostname,
		"systemd_available": s.manager.SystemdAvailable(r.Context()),
		"now":               time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleServices(w http.ResponseWriter, r *http.Request) {
	if !s.preflight(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Only GET is supported.")
		return
	}
	if !authorize(s.config, r) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Missing or invalid token.")
		return
	}

	services, err := s.manager.ListServices(r.Context(), r.URL.Query().Get("query"))
	if err != nil {
		s.writeManagerError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"services": services})
}

func (s *Server) handleServiceResource(w http.ResponseWriter, r *http.Request) {
	if !s.preflight(w, r) {
		return
	}
	if !authorize(s.config, r) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Missing or invalid token.")
		return
	}

	trimmed := strings.TrimPrefix(r.URL.Path, "/api/v1/services/")
	parts := strings.Split(trimmed, "/")
	if len(parts) == 0 || parts[0] == "" {
		writeError(w, http.StatusNotFound, "not_found", "Missing service name.")
		return
	}
	serviceName := parts[0]

	switch {
	case len(parts) == 1 && r.Method == http.MethodGet:
		service, err := s.manager.GetService(r.Context(), serviceName)
		if err != nil {
			s.writeManagerError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"service": service})
	case len(parts) == 2 && parts[1] == "actions" && r.Method == http.MethodPost:
		s.handleServiceAction(w, r, serviceName)
	case len(parts) == 2 && parts[1] == "logs" && r.Method == http.MethodGet:
		s.handleServiceLogs(w, r, serviceName)
	default:
		writeError(w, http.StatusNotFound, "not_found", "Unknown service endpoint.")
	}
}

func (s *Server) handleServiceAction(w http.ResponseWriter, r *http.Request, serviceName string) {
	var request struct {
		Action string `json:"action"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_action", "Invalid request body.")
		return
	}

	service, err := s.manager.Action(r.Context(), serviceName, request.Action)
	if err != nil {
		s.writeManagerError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"service": service})
}

func (s *Server) handleServiceLogs(w http.ResponseWriter, r *http.Request, serviceName string) {
	lines := s.config.LogTailDefaultLines
	if rawLines := r.URL.Query().Get("lines"); rawLines != "" {
		parsedLines, err := strconv.Atoi(rawLines)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_lines", "lines must be an integer.")
			return
		}
		lines = parsedLines
	}

	logs, err := s.manager.RecentLogs(r.Context(), serviceName, lines)
	if err != nil {
		s.writeManagerError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"logs": logs})
}

func (s *Server) handleLogStream(w http.ResponseWriter, r *http.Request) {
	if !corsHeaders(w, r, s.config) {
		return
	}
	if !authorize(s.config, r) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Missing or invalid token.")
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Only GET is supported.")
		return
	}

	serviceName := r.URL.Query().Get("service")
	if serviceName == "" {
		writeError(w, http.StatusBadRequest, "invalid_service", "service query parameter is required.")
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		s.logger.Printf("websocket upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	entryCh, errCh, stopFn, err := s.manager.FollowLogs(ctx, serviceName)
	if err != nil {
		_ = conn.WriteJSON(map[string]any{
			"type":    "error",
			"message": err.Error(),
		})
		return
	}
	defer stopFn()

	for {
		select {
		case <-ctx.Done():
			return
		case entry, ok := <-entryCh:
			if !ok {
				return
			}
			if err := conn.WriteJSON(map[string]any{
				"type":    "log",
				"service": entry.Service,
				"line":    entry.Line,
				"ts":      entry.TS,
			}); err != nil {
				return
			}
		case err, ok := <-errCh:
			if !ok {
				return
			}
			_ = conn.WriteJSON(map[string]any{
				"type":    "error",
				"message": err.Error(),
			})
			return
		}
	}
}

func (s *Server) preflight(w http.ResponseWriter, r *http.Request) bool {
	if !corsHeaders(w, r, s.config) {
		return false
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	return true
}

func (s *Server) writeManagerError(w http.ResponseWriter, err error) {
	message := err.Error()
	switch {
	case strings.Contains(message, "invalid action"):
		writeError(w, http.StatusBadRequest, "invalid_action", message)
	case strings.Contains(message, "invalid service name"),
		strings.Contains(message, "service \""):
		writeError(w, http.StatusBadRequest, "invalid_service", message)
	case strings.Contains(message, "list services"),
		strings.Contains(message, "show service"),
		strings.Contains(message, "journalctl"),
		strings.Contains(message, "systemctl"):
		writeError(w, http.StatusBadGateway, "command_failed", message)
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", message)
	}
}

func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		startedAt := time.Now()
		next.ServeHTTP(recorder, r)
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		s.logger.Printf(
			"%s %s %s %d %s",
			host,
			r.Method,
			r.URL.Path,
			recorder.status,
			time.Since(startedAt).Round(time.Millisecond),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("response writer does not support hijacking")
	}
	return hijacker.Hijack()
}
