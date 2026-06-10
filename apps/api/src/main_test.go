package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	rr := httptest.NewRecorder()
	healthzHandler(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("healthz = %d, want 200", rr.Code)
	}
}

func TestReadyzReportsDB(t *testing.T) {
	dbReady = false
	rr := httptest.NewRecorder()
	readyzHandler(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz(not ready) = %d, want 503", rr.Code)
	}
	dbReady = true
	rr = httptest.NewRecorder()
	readyzHandler(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("readyz(ready) = %d, want 200", rr.Code)
	}
}

func TestMigrateExitsZero(t *testing.T) {
	if err := runMigrate(); err != nil {
		t.Fatalf("migrate returned err: %v", err)
	}
}
