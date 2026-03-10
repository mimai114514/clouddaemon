package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"clouddaemon-agent/internal/config"
	"clouddaemon-agent/internal/httpapi"
	"clouddaemon-agent/internal/systemd"
)

const version = "1.0.0"

func main() {
	configPath := flag.String("config", "config.yaml", "Path to the YAML config file.")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	executor := systemd.NewExecRunner()
	manager := systemd.NewManager(executor)
	server, err := httpapi.NewServer(httpapi.Options{
		Version: version,
		Config:  cfg,
		Manager: manager,
		Logger:  log.New(os.Stdout, "", log.LstdFlags),
	})
	if err != nil {
		log.Fatalf("create server: %v", err)
	}

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("clouddaemon-agent listening on %s", cfg.ListenAddr)
		if err := httpServer.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile); err != nil && err != http.ErrServerClosed {
			log.Fatalf("serve https: %v", err)
		}
	}()

	signalCh := make(chan os.Signal, 1)
	signal.Notify(signalCh, syscall.SIGINT, syscall.SIGTERM)
	<-signalCh

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(ctx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
}
