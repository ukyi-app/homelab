package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	dbReady  = false
	draining atomic.Bool
)

func healthzHandler(w http.ResponseWriter, _ *http.Request) {
	// liveness: process is up, NO external deps.
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func readyzHandler(w http.ResponseWriter, _ *http.Request) {
	// readiness: flips to 503 while draining or if DB not reachable.
	if draining.Load() || !dbReady {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("not ready"))
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func metricsHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintln(w, "# HELP app_up 1 if the app is serving")
	fmt.Fprintln(w, "# TYPE app_up gauge")
	fmt.Fprintln(w, "app_up 1")
}

func runMigrate() error {
	// app-native migration entrypoint. Real impl runs golang-migrate against DATABASE_URL.
	// Idempotent + backward-compatible (expand/contract). No-op when nothing to do.
	fmt.Println("migrate: schema up to date")
	return nil
}

func checkDB() {
	// Probe DATABASE_URL; here we mark ready if the env is present.
	if os.Getenv("DATABASE_URL") != "" {
		dbReady = true
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "migrate" {
		if err := runMigrate(); err != nil {
			fmt.Fprintln(os.Stderr, "migrate failed:", err)
			os.Exit(1)
		}
		return
	}

	checkDB()

	appMux := http.NewServeMux()
	appMux.HandleFunc("/healthz", healthzHandler)
	appMux.HandleFunc("/readyz", readyzHandler)
	appMux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("homelab api\n"))
	})
	appSrv := &http.Server{Addr: ":8080", Handler: appMux}

	metricsMux := http.NewServeMux()
	metricsMux.HandleFunc("/metrics", metricsHandler)
	metricsSrv := &http.Server{Addr: ":9090", Handler: metricsMux}

	go func() { _ = metricsSrv.ListenAndServe() }()
	go func() {
		if err := appSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(os.Stderr, "server error:", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	// SIGTERM drain: flip readyz -> 503, finish in-flight, exit < 30s.
	draining.Store(true)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	_ = appSrv.Shutdown(ctx)
	_ = metricsSrv.Shutdown(ctx)
}
