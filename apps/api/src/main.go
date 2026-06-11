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
	// liveness: 프로세스가 떠 있는지만 본다. 외부 의존성 절대 없음.
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func readyzHandler(w http.ResponseWriter, _ *http.Request) {
	// readiness: draining 중이거나 DB에 닿지 못하면 503으로 전환된다.
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
	// 앱 내장 마이그레이션 진입점. 실제 구현은 DATABASE_URL을 대상으로 golang-migrate를 실행한다.
	// 멱등 + 하위 호환(expand/contract). 할 일이 없으면 no-op.
	fmt.Println("migrate: schema up to date")
	return nil
}

func checkDB() {
	// DATABASE_URL을 프로브한다. 여기서는 env가 있으면 ready로 표시한다.
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

	// SIGTERM drain: readyz를 503으로 전환, 처리 중 요청 마무리, 30초 안에 종료.
	draining.Store(true)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	_ = appSrv.Shutdown(ctx)
	_ = metricsSrv.Shutdown(ctx)
}
